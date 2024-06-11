

helm --namespace o2 -f t_values.yaml install o2 .

helm -n o2 -f t_values.yaml upgrade --install o2 .

helm --namespace o2 delete o2





