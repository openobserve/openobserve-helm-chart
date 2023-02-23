# Zinc Observe helm chart

Clone the repo, update values.yaml file as per your requirements and run below commands to:

## Amazon EKS

You must set a minimum of 2 values:

1. S3 bucket where data will be stored
    - config.ZO_S3_BUCKET_NAME
1. IAM role for the serviceAccount to gain AWSIAM credentials to access s3
    - serviceAccount.annotations."eks.amazonaws.com/role-arn"

## Install

helm install observe1 .


## Uninstall

helm delete observe1






