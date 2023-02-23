# Zinc Observe helm chart

Clone the repo, update values.yaml file as per your requirements and run below commands to:

## Amazon EKS

ZincObserve uses [IRSA](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html) on Amazon EKS to securely access s3.

You must set a minimum of 2 values:

1. S3 bucket where data will be stored
    - config.ZO_S3_BUCKET_NAME
1. IAM role for the serviceAccount to gain AWS IAM credentials to access s3
    - serviceAccount.annotations."eks.amazonaws.com/role-arn"

## Install

helm install observe1 .


## Uninstall

helm delete observe1






