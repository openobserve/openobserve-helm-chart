#!/bin/sh

helm package .

helm repo index --url https://charts.zinc.dev .

aws s3 cp index.yaml s3://zincsearch-releases/charts/index.yaml

aws s3 cp *.tgz s3://zincsearch-releases/charts/

# invalidate cludfront cache

aws cloudfront create-invalidation --distribution-id E1MZFY4I0CFJV9 --paths=/*

