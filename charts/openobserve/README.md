# openobserve helm chart

## Amazon EKS

openobserve uses [IRSA](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html) on Amazon EKS to securely access s3.

You must set a minimum of 2 values:

1. S3 bucket where data will be stored
   - config.ZO_S3_BUCKET_NAME
1. IAM role for the serviceAccount to gain AWS IAM credentials to access s3
   - serviceAccount.annotations."eks.amazonaws.com/role-arn"

## Install

```shell
helm repo add openobserve https://charts.openobserve.ai
helm repo update

kubectl create ns openobserve

helm --namespace openobserve -f values.yaml install o1 openobserve/openobserve
```

## Uninstall

```shell
helm delete o1
```

# Development

If you are developing this chart then you should clone the repo and make any modifications.

You can generate output of the chart using below command to verify:

```shell
helm -n openobserve template o1 . > o1.yaml
```

You can then install using:

```shell
helm -n openobserve install o1 .
```

To upgrade

```shell
helm -n openobserve upgrade o1 .
```

To uninstall

```shell
helm -n openobserve uninstall o1 .
```
