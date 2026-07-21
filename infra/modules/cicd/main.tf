# CI/CD module - GitHub Actions OIDC federation plus the one role the
# deploy workflow assumes. No long-lived AWS credentials are stored in
# GitHub: the workflow exchanges its short-lived OIDC token for temporary
# AWS credentials via sts:AssumeRoleWithWebIdentity, and the trust policy
# below pins that exchange to exactly one repo and one branch.

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # AWS validates the token against its own trusted CA bundle and no
  # longer actually checks this value, but the provider resource still
  # requires a thumbprint at creation.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = {
    Name = "${var.name_prefix}-github-oidc"
  }
}

# --- Deploy role ------------------------------------------------------------
# Trust is scoped two ways at once: `aud` must be the STS audience GitHub
# sets for AWS federation, and `sub` must match this exact repo on main -
# no fork, no PR branch, no other repo can ever assume this role.

data "aws_iam_policy_document" "deploy_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      # GitHub can issue ID-embedded subject claims (owner@id/repo@id); pinning
      # the numeric ids survives renames and blocks name re-registration attacks.
      values = [
        "repo:${var.repo}:ref:refs/heads/main",
        "repo:ChristianOrrala@8031432/Tech-Challenge-TCGL01@1307194583:ref:refs/heads/main",
      ]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name               = "${var.name_prefix}-deploy"
  assume_role_policy = data.aws_iam_policy_document.deploy_assume.json

  tags = {
    Name = "${var.name_prefix}-deploy"
  }
}

# --- Permissions --------------------------------------------------------
# PowerUserAccess + a narrow, project-prefixed IAM grant instead of a
# blanket admin role: PowerUserAccess deliberately excludes IAM principal
# management, so this pipeline can create or change every resource this
# stack needs except IAM roles/policies - the inline policy below restores
# just enough of that gap for Terraform to manage this project's own
# roles and policies (named "${var.name_prefix}-*"), never account-wide.
# A real production pipeline would go further and attach a permissions
# boundary to every role this identity is allowed to create.

resource "aws_iam_role_policy_attachment" "deploy_poweruser" {
  role       = aws_iam_role.deploy.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

data "aws_iam_policy_document" "iam_project_scoped" {
  statement {
    sid = "ProjectIamManagement"

    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:GetRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:PassRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]

    resources = [
      "arn:aws:iam::*:role/${var.name_prefix}-*",
      "arn:aws:iam::*:policy/${var.name_prefix}-*",
    ]
  }

  statement {
    sid = "OidcProviderMaintenance"

    actions = [
      "iam:GetOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
      "iam:TagOpenIDConnectProvider",
    ]

    resources = [aws_iam_openid_connect_provider.github.arn]
  }

  statement {
    sid = "ServiceLinkedRoleCreation"

    # RDS, ECS, and the ALB each create their own service-linked role on
    # first use in an account. PowerUserAccess excludes all IAM actions,
    # so without this the very first apply would fail the moment any of
    # those services tried to create its SLR. Not scopable to the
    # project prefix - SLR names are fixed by each AWS service.
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
  }

  statement {
    sid    = "DenySelfModification"
    effect = "Deny"

    # Privilege-escalation guard: the project-prefix grant would otherwise
    # match this role's own name; deny always wins over allow.
    actions = [
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:UpdateAssumeRolePolicy",
      "iam:UpdateRole",
      "iam:DeleteRole",
      "iam:TagRole",
      "iam:UntagRole",
    ]

    resources = [aws_iam_role.deploy.arn]
  }
}

resource "aws_iam_role_policy" "iam_project_scoped" {
  name   = "iam-project-scoped"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.iam_project_scoped.json
}
