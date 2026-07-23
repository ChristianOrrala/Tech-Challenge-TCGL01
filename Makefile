.PHONY: bootstrap init plan apply destroy image seed package-ingestion

TF_DIR := infra
AWS_REGION ?= us-east-2
STATE_BUCKET ?=

# Windows note: run make from Git Bash so recipes execute under a POSIX shell.

bootstrap:
	$(if $(STATE_BUCKET),,$(error STATE_BUCKET is required))
	aws s3api create-bucket --bucket $(STATE_BUCKET) --region $(AWS_REGION) --create-bucket-configuration LocationConstraint=$(AWS_REGION)
	aws s3api put-bucket-versioning --bucket $(STATE_BUCKET) --versioning-configuration Status=Enabled
	aws s3api put-public-access-block --bucket $(STATE_BUCKET) --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

init:
	terraform -chdir=$(TF_DIR) init -backend-config=envs/demo/backend.hcl

plan:
	terraform -chdir=$(TF_DIR) plan -var-file=envs/demo/common.tfvars -var-file=envs/demo/demo.tfvars -var "image_tag=$$(git rev-parse --short HEAD)" -out=tfplan

apply:
	terraform -chdir=$(TF_DIR) apply tfplan

destroy:
	terraform -chdir=$(TF_DIR) destroy -var-file=envs/demo/common.tfvars -var-file=envs/demo/demo.tfvars

image:
	ACCOUNT=$$(aws sts get-caller-identity --query Account --output text) && \
	aws ecr get-login-password --region $(AWS_REGION) | docker login --username AWS --password-stdin $$ACCOUNT.dkr.ecr.$(AWS_REGION).amazonaws.com && \
	docker build -t tcgl01-api app/api && \
	docker tag tcgl01-api $$ACCOUNT.dkr.ecr.$(AWS_REGION).amazonaws.com/tcgl01-api:latest && \
	docker tag tcgl01-api $$ACCOUNT.dkr.ecr.$(AWS_REGION).amazonaws.com/tcgl01-api:$$(git rev-parse --short HEAD) && \
	docker push $$ACCOUNT.dkr.ecr.$(AWS_REGION).amazonaws.com/tcgl01-api:latest && \
	docker push $$ACCOUNT.dkr.ecr.$(AWS_REGION).amazonaws.com/tcgl01-api:$$(git rev-parse --short HEAD)

seed:
	aws lambda invoke --function-name tcgl01-ingestion --region $(AWS_REGION) seed-output.json
	cat seed-output.json

# Vendors psycopg[binary] for the Lambda runtime (manylinux2014_x86_64 /
# Python 3.12) rather than whatever wheel the local host would resolve -
# on a non-Linux host, a plain `pip install` would pull win_amd64/macosx
# wheels and the function would fail to import psycopg at runtime.
# typing_extensions is vendored explicitly too - pip evaluates dependency
# markers against the HOST interpreter, so on Python >= 3.13 hosts,
# psycopg's typing_extensions dependency is silently omitted from the
# 3.12 target zip.
package-ingestion:
	python -m pip install --quiet "psycopg[binary]" "typing_extensions" --platform manylinux2014_x86_64 --only-binary=:all: --python-version 3.12 --target ingestion/build --upgrade
	cp ingestion/handler.py ingestion/build/handler.py
