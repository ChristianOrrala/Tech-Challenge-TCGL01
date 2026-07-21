.PHONY: bootstrap init plan apply destroy image seed

TF_DIR := infra
AWS_REGION ?= us-east-2
STATE_BUCKET ?=

bootstrap:
	$(if $(STATE_BUCKET),,$(error STATE_BUCKET is required))
	aws s3api create-bucket --bucket $(STATE_BUCKET) --region $(AWS_REGION) --create-bucket-configuration LocationConstraint=$(AWS_REGION)
	aws s3api put-bucket-versioning --bucket $(STATE_BUCKET) --versioning-configuration Status=Enabled
	aws s3api put-public-access-block --bucket $(STATE_BUCKET) --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

init:
	terraform -chdir=$(TF_DIR) init -backend-config=envs/demo/backend.hcl

plan:
	terraform -chdir=$(TF_DIR) plan -var-file=envs/demo/demo.tfvars -out=tfplan

apply:
	terraform -chdir=$(TF_DIR) apply tfplan

destroy:
	terraform -chdir=$(TF_DIR) destroy -var-file=envs/demo/demo.tfvars

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
