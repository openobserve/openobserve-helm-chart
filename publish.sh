#!/bin/sh

# Any extra files will bloat the chart and make it fail to install.
rm -rf artifacts
rm *.tgz

# Update dependencies
helm dependency update

# build the chart.
helm package .

# copy all previous charts from s3 so we can update the index
aws s3 sync s3://zincsearch-releases/charts/ .

# update the index
helm repo index --url https://charts.zinc.dev .

mkdir artifacts
cp -r index.yaml artifacts/index.yaml
cp -r *.tgz artifacts/
aws s3 sync artifacts s3://zincsearch-releases/charts/
aws s3 sync charts s3://zincsearch-releases/charts/charts/

# invalidate cludfront cache
aws cloudfront create-invalidation --distribution-id E1MZFY4I0CFJV9 --paths=/*

rm -rf artifacts
rm *.tgz
