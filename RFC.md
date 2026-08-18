NODEPOOL="my-nodepool"

for node in $(kubectl get nodes \
  -l "karpenter.sh/nodepool=${NODEPOOL}" \
  -o jsonpath='{.items[*].metadata.name}'); do

  kubectl get pods -A \
    --field-selector spec.nodeName="$node" \
    -o custom-columns='NS:.metadata.namespace,KIND:.metadata.ownerReferences[0].kind,OWNER:.metadata.ownerReferences[0].name' \
    --no-headers

done | while read ns kind owner; do

  case "$kind" in

    StatefulSet)
      echo "$ns StatefulSet $owner"
      ;;

    ReplicaSet)
      deployment=$(kubectl get rs "$owner" \
        -n "$ns" \
        -o jsonpath='{.metadata.ownerReferences[?(@.kind=="Deployment")].name}' \
        2>/dev/null)

      if [ -n "$deployment" ]; then
        echo "$ns Deployment $deployment"
      fi
      ;;

  esac

done | sort -u
