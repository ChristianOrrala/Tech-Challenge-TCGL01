<#
.SYNOPSIS
    PowerShell task runner mirroring the project's Makefile targets, for native
    Windows PowerShell / pwsh use (no Git Bash required).

.EXAMPLE
    ./make.ps1 plan

.EXAMPLE
    ./make.ps1 bootstrap -StateBucket my-tf-state-bucket
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('bootstrap', 'init', 'plan', 'apply', 'destroy', 'image', 'deploy-web', 'seed', 'package-ingestion', 'help')]
    [string]$Task = 'help',

    [string]$AwsRegion = $(if ($env:AWS_REGION) { $env:AWS_REGION } else { 'us-east-2' }),
    [string]$StateBucket = $env:STATE_BUCKET,
    [string]$TfDir = 'infra'
)

$ErrorActionPreference = 'Stop'

function Invoke-Checked {
    param([Parameter(Mandatory)][scriptblock]$Command)
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE"
    }
}

function Get-GitShortSha {
    $sha = git rev-parse --short HEAD
    if ($LASTEXITCODE -ne 0) { throw 'git rev-parse failed' }
    return $sha
}

function Show-Help {
    @'
Usage: ./make.ps1 <task> [-AwsRegion <region>] [-StateBucket <name>] [-TfDir <path>]

Tasks:
  bootstrap           Create the Terraform state S3 bucket (requires -StateBucket)
  init                terraform init against the demo backend
  plan                terraform plan against the demo tfvars (writes tfplan)
  apply               terraform apply of the saved tfplan
  destroy             terraform destroy against the demo tfvars
  image               Build, tag and push the API image to ECR
  deploy-web          Build the SPA and sync it to S3 + invalidate CloudFront
  seed                Invoke the ingestion Lambda and print its output
  package-ingestion   Vendor psycopg[binary] for the Lambda runtime

Options (fall back to env vars AWS_REGION / STATE_BUCKET, like the Makefile):
  -AwsRegion   <region>  Default: us-east-2
  -StateBucket <name>    Required for 'bootstrap'
  -TfDir       <path>    Default: infra
'@
}

function Invoke-Bootstrap {
    if (-not $StateBucket) {
        throw 'STATE_BUCKET is required. Pass -StateBucket <name> or set $env:STATE_BUCKET.'
    }
    Invoke-Checked { aws s3api create-bucket --bucket $StateBucket --region $AwsRegion --create-bucket-configuration LocationConstraint=$AwsRegion }
    Invoke-Checked { aws s3api put-bucket-versioning --bucket $StateBucket --versioning-configuration Status=Enabled }
    Invoke-Checked { aws s3api put-public-access-block --bucket $StateBucket --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true }
}

function Invoke-Init {
    Invoke-Checked { terraform "-chdir=$TfDir" init "-backend-config=envs/demo/backend.hcl" }
}

function Invoke-Plan {
    $sha = Get-GitShortSha
    Invoke-Checked { terraform "-chdir=$TfDir" plan "-var-file=envs/demo/demo.tfvars" -var "image_tag=$sha" "-out=tfplan" }
}

function Invoke-Apply {
    Invoke-Checked { terraform "-chdir=$TfDir" apply tfplan }
}

function Invoke-Destroy {
    Invoke-Checked { terraform "-chdir=$TfDir" destroy "-var-file=envs/demo/demo.tfvars" }
}

function Invoke-Image {
    $account = aws sts get-caller-identity --query Account --output text
    if ($LASTEXITCODE -ne 0) { throw 'aws sts get-caller-identity failed' }
    $sha = Get-GitShortSha
    $registry = "$account.dkr.ecr.$AwsRegion.amazonaws.com"

    aws ecr get-login-password --region $AwsRegion | docker login --username AWS --password-stdin $registry
    if ($LASTEXITCODE -ne 0) { throw 'docker login failed' }

    Invoke-Checked { docker build -t tcgl01-api app/api }
    Invoke-Checked { docker tag tcgl01-api "$registry/tcgl01-api:latest" }
    Invoke-Checked { docker tag tcgl01-api "$registry/tcgl01-api:$sha" }
    Invoke-Checked { docker push "$registry/tcgl01-api:latest" }
    Invoke-Checked { docker push "$registry/tcgl01-api:$sha" }
}

function Get-TfOutput {
    param([Parameter(Mandatory)][string]$Name)
    $value = terraform "-chdir=$TfDir" output -raw $Name
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) {
        throw "Could not read '$Name' from terraform output. Has the stack been applied?"
    }
    return $value
}

function Invoke-DeployWeb {
    # Mirrors the 'build web -> sync spa -> invalidate' steps of
    # .github/workflows/deploy.yml. The local apply path stands the S3 bucket
    # and CloudFront up but never populates the bucket, so the public domain
    # serves Access Denied (CloudFront asks S3 for index.html, the OAC-only
    # bucket returns 403 for the missing object) until the SPA is synced here.
    Push-Location app/web
    try {
        Invoke-Checked { npm ci }
        Invoke-Checked { npm run build }
    }
    finally {
        Pop-Location
    }

    $bucket = Get-TfOutput -Name 'spa_bucket_name'
    $distId = Get-TfOutput -Name 'distribution_id'

    Invoke-Checked { aws s3 sync app/web/dist "s3://$bucket" --delete }
    Invoke-Checked { aws cloudfront create-invalidation --distribution-id $distId --paths "/*" }
}

function Invoke-Seed {
    Invoke-Checked { aws lambda invoke --function-name tcgl01-ingestion --region $AwsRegion seed-output.json }
    Get-Content seed-output.json
}

function Invoke-PackageIngestion {
    # Vendors psycopg[binary] for the Lambda runtime (manylinux2014_x86_64 /
    # Python 3.12) rather than whatever wheel the local host would resolve -
    # on a non-Linux host, a plain `pip install` would pull win_amd64/macosx
    # wheels and the function would fail to import psycopg at runtime.
    # typing_extensions is vendored explicitly too - pip evaluates dependency
    # markers against the HOST interpreter, so on Python >= 3.13 hosts,
    # psycopg's typing_extensions dependency is silently omitted from the
    # 3.12 target zip.
    Invoke-Checked {
        python -m pip install --quiet "psycopg[binary]" "typing_extensions" --platform manylinux2014_x86_64 --only-binary=:all: --python-version 3.12 --target ingestion/build --upgrade
    }
    Copy-Item -Path ingestion/handler.py -Destination ingestion/build/handler.py -Force
}

switch ($Task) {
    'bootstrap'         { Invoke-Bootstrap }
    'init'              { Invoke-Init }
    'plan'              { Invoke-Plan }
    'apply'             { Invoke-Apply }
    'destroy'           { Invoke-Destroy }
    'image'             { Invoke-Image }
    'deploy-web'        { Invoke-DeployWeb }
    'seed'              { Invoke-Seed }
    'package-ingestion' { Invoke-PackageIngestion }
    default             { Show-Help }
}
