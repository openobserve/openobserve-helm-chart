#! /bin/bash

# helm repo update

helm -n openobserve-collector -f values-common.yaml upgrade --install o2c .

# helm template -n openobserve-collector -f values-common.yaml o2c . > o2c.yaml

# helm template -n openobserve-collector -f values.yaml oc1 openobserve/openobserve-collector > oc1.yaml


# To delete openobserve collector deployment:
# helm -n openobserve-collector delete oc1
