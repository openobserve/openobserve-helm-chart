# ZincObserve helm chart

## Amazon EKS

ZincObserve uses [IRSA](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html) on Amazon EKS to securely access s3.

You must set a minimum of 2 values:

1. S3 bucket where data will be stored
    - config.ZO_S3_BUCKET_NAME
1. IAM role for the serviceAccount to gain AWS IAM credentials to access s3
    - serviceAccount.annotations."eks.amazonaws.com/role-arn"

## Install

```shell
helm repo add zinc https://charts.zinc.dev
helm repo update

kubectl create ns zincobserve


helm --namespace zincobserve -f values.yaml install zo1 zinc/zincobserve
```

## Uninstall

```shell
helm delete observe1
```





