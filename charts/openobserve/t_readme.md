

helm --namespace ent5 -f t_values.yaml install o2 .

helm -n ent5 -f t_values.yaml upgrade --install o2 .

helm --namespace ent5 delete o2





