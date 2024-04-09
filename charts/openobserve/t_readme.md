

helm --namespace qsec0 -f t_values.yaml install o2 .

helm -n qsec0 -f t_values.yaml upgrade --install o2 .

helm --namespace qsec0 delete o2





