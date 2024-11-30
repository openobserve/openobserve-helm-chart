#!/bin/bash

# Package all charts
for d in charts/* ; do
    helm dependency update "$d"
    helm package "$d"
done

# Create the Helm Repo Index and merge it with the existing index.yaml
helm repo index --merge index.yaml .

# Upload the charts to the S3 bucket
aws s3 cp . s3://zincsearch-releases/chartsv2/ --recursive --exclude "*" --include "*.tgz" --profile=o2-dev

# delete the charts after upload
rm *.tgz

# upload the index.yaml
aws s3 cp index.yaml s3://zincsearch-releases/chartsv2/ --profile=o2-dev

# invalidate cludfront cache
aws cloudfront create-invalidation --distribution-id E1KAOPVKDAGD4X --paths="/*" --profile=o2-dev
