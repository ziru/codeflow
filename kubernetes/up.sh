#!/bin/bash -e

echo This script helps configure codeflow for the initial deployment into a K8S environment.
echo REQUIRES: jq
echo
echo Additional settings can be configured prior to running this script by editing the files:
echo "* codeflow-services.yaml (optional annotations for your service like SSL)"
echo "* ../server/configs/codeflow.yml (optional)"
echo 
if [ -z "$NONINTERACTIVE" ]; then
	read -p "Continue with the current settings? (y/n)" yn
	if [ "$yn" != "y" ]; then
		echo Aborting..
		exit 1
	fi
fi

# This requires jq to be installed
if [ ! -x "$(command -v jq)" ]; then
	echo up.sh requires jq to be installed.
	echo OSX: brew install jq
	echo Linux: apt-get
	exit 1
fi


wait_for_ingress_hostname () {
	local hostname=$(kubectl get services --namespace=development-checkr-codeflow -ojson |jq -r ".items[] | select(.metadata.name==\"codeflow\") | .status.loadBalancer.ingress[0].hostname")
	until [ -n "$hostname" ]; do
		echo waiting for hostname...
		sleep 5
	done
}
 
# get_url 'servicename' 'scheme'
get_url () {
	url=${2}://$(kubectl get services --namespace=development-checkr-codeflow -ojson |jq -r ".items[] | select(.metadata.name==\"codeflow\") | [ .status.loadBalancer.ingress[0].hostname, (.spec.ports[] | select(.name==\"${1}\") | .port |tostring) ] |join(\":\")")
}

get_dashboard_port () {
	port=$(kubectl get services --namespace=development-checkr-codeflow -ojson |jq ".items[] | select(.metadata.name==\"codeflow\") | .spec.ports[] | select(.name==\"dashboard-port\") | .port |tostring")
}

detect_ssl () {
	ssl_arn=$(kubectl get services --namespace=development-checkr-codeflow -ojson |jq -r ".items[] | select(.metadata.name==\"codeflow\") |.metadata.annotations.\"service.beta.kubernetes.io\/aws-load-balancer-ssl-cert\"")
	if [ -n "$ssl_arn" ] && [ "$ssl_arn" != "null" ]; then
		echo Using TCP+SSL protocol..
		protocol=s
	fi
}

echo creating namespace development-checkr-codeflow
kubectl create namespace development-checkr-codeflow

echo creating mongodb and redis
kubectl create -f mongodb-service.yaml
kubectl create -f mongodb-deployment.yaml
kubectl create -f redis-service.yaml
kubectl create -f redis-deployment.yaml

echo creating codeflow services
kubectl create -f codeflow-services.yaml

echo configuring codeflow dashboard
envfile=react-configmap.yaml
cat << EOF > $envfile
# This ConfigMap is used to configure codeflow react service (dashboard).
kind: ConfigMap
apiVersion: v1
metadata:
  name: react-config
  namespace: development-checkr-codeflow
data:
EOF

detect_ssl

wait_for_ingress_hostname

get_url 'api-port' "http${protocol}"
echo "  REACT_APP_API_ROOT: $url" >> $envfile

get_url 'webhooks-port' "http${protocol}"
echo "  REACT_APP_WEBHOOKS_ROOT: $url" >> $envfile

get_url 'websockets-port' "ws${protocol}"
echo "  REACT_APP_WS_ROOT: $url" >> $envfile

get_url 'dashboard-port' "http${protocol}"
echo "  REACT_APP_ROOT: $url"  >> $envfile

get_dashboard_port
echo "  REACT_APP_PORT: $port"  >> $envfile

kubectl apply -f $envfile --namespace=development-checkr-codeflow 

echo react-configmap generated and applied from file: $envfile
echo Services configured successfully..
echo
echo Dashboard URL:  $url

echo
echo configuring codeflow api
kubectl create configmap codeflow-config --from-file=../server/configs/codeflow.yml --namespace=development-checkr-codeflow

echo creating codeflow deployment
kubectl create -f codeflow-deployment.yaml
