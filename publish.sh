#!/bin/sh

mkdir package
mkdir package/charts
mkdir package/templates

cp -r charts/* ./package/charts/
cp -r templates/* ./package/templates/
cp Chart.yaml ./package/
cp Chart.lock ./package/
cp index.yaml ./package/
cp values.yaml ./package/
cp .helmignore ./package/


cd package

# Update dependencies
helm dependency update

# build the chart.
helm package .

# copy all previous charts from s3 so we can update the index
aws s3 sync s3://zincsearch-releases/charts-openobserve/ . --profile=dev

# update the index
helm repo index --url https://charts.openobserve.ai .

mkdir artifacts
cp -r index.yaml artifacts/index.yaml
cp -r *.tgz artifacts/
aws s3 sync artifacts s3://zincsearch-releases/charts-openobserve/ --profile=dev
aws s3 sync charts s3://zincsearch-releases/charts-openobserve/charts/ --profile=dev

# copy manifests back to parent
cp -r Chart.lock ../Chart.lock
cp -r index.yaml ../index.yaml

# invalidate cludfront cache
aws cloudfront create-invalidation --distribution-id E1KAOPVKDAGD4X --paths="/*" --profile=dev

cd ..
rm -rf package
# rm -rf artifacts
# rm *.tgz
