--------------------- Preparation steps  ------------------------
# Intall kubectl
# Install kfctl
# Install Docker
# Install az
# Create or obtain an Azure subscription
# Create a resource group in the subscription in a region

alias k='kubectl'

SUB=<Azure sbuscription name or id>
REGION=<region, e.g. eastus>
RG=<resource group, e.g. aks-eastus>
CLUSTER=<cluster name, e.g. aks-ml-demo>
NODEPOOL=<node pool name, e.g. pool2>
SP=<service principal client-id, e.g. a1d6ea22-ed13-1111-9999-a121999a3aaa>
SECRETE=<service principal secret>
ACR=<Azure container registry name, e.g. ml-demo>


# -------------------  To find SP and tenant id  -----------
az ad sp list --show-mine --query "[].{id:appId, tenant:appOwnerTenantId}"

# -------------------  Create Resource Group  --------------  
az login
az account set --subscription="$SUB"
az group create -l "$REGION" -n "$RG" --subscription "$SUB"

# ----------------------  Create ACR  ----------------------  

az acr create --subscription "$SUB" --name "$ACR" -g "$RG" -l "$REGION"  --sku Standard
ACR_REGISTRY_ID=$(az acr show --name "$ACR" --query id --output tsv)
az role assignment create --assignee $SP --scope $ACR_REGISTRY_ID --role acrpull
az acr login -n $ACR

# -----------   Get supported K8S versions and vm sizes -----------------
az aks get-versions -l $REGION | jq '.orchestrators | .[].orchestratorVersion' | sort
az vm list-sizes -l "$REGION" -o table

# ----------------------  Create AKS Cluster  ------------------------

# Create cluster with 2 nodepools for future expansion
time az aks create --subscription "$SUB"  -g "$RG" --no-ssh-key\
  -n $CLUSTER \
  --node-count 1 -s Standard_DS3_v2 --kubernetes-version=1.14.7 --nodepool-name=infra \
  --service-principal "$SP" --client-secret "$SECRET"

time az aks nodepool add --subscription "$SUB"  -g "$RG" \
  --cluster-name "$CLUSTER" \
  --node-count 3 --node-vm-size Standard_DS3_v2 --kubernetes-version 1.14.7 --name "$NODEPOOL" 

# Show cluster
az aks show --subscription "$SUB" -g "$RG" -n "$CLUSTER"

# Get AKS cluster credential into a file
CONFIGFILE=~/.kube/config.$CLUSTER
az aks get-credentials --subscription "$SUB" -g $RG -n $CLUSTER -a -f "$CONFIGFILE"
export KUBECONFIG="$CONFIGFILE"


# -----------  Install kubeflow to the cluster  ---------------------

# Create folder to hold kf app files
# skip the following steps if you've done it, such as to another cluster
mkdir -p ~/kfapp
cd ~/kfapp
kfctl init ~/kfapp --config=https://raw.githubusercontent.com/kubeflow/kubeflow/v0.6.2/bootstrap/config/kfctl_k8s_istio.0.6.2.yaml
kfctl generate all -V 

# Apply the yaml files to K8S cluster to create kubeflow,istio, jupyter, graffana resources and controllers.
cd ~/kfapp
kfctl apply all -V  # This takes 2.5 minutes, 1.5 waiting for kubeflow-anonymous namespace to show up

# Set kubeflow as default namespace in the context
kubectl config set-context $(kubectl config current-context) --namespace=kubeflow


# See dashboard
kubectl port-forward svc/istio-ingressgateway -n istio-system 8080:80

# --------- Edit a Jupyter Notebook   -------------
# Then on the dashboard, create a new notebook server
# Connect to the notebook server and start a new notebook
# Each notebook server is a pod and each notebook is a python process in the pod.

# Find the pod deployed for the notebook server:
k get pod -n kubeflow-anonymous

# Check the processes for the notebooks inside the notebook server, suppose test1 is the notebook server name.
NOTEBOOKSERVER="test1"
k -n kubeflow-anonymous exec -it pod/${NOTEBOOKSERVER}-0 -- /bin/sh


# --------- MNIST on Kubeflow example -------------
# ------------- TRAINING  ----------------

# Build and push the model image to container registry
# Follow: https://github.com/kubeflow/examples/tree/master/mnist#build-and-push-model-image
# Pick a folder to clone the examples or  cd ..
git clone http://github.com/kubeflow/examples

cd ./examples/mnist
MNIST_ROOT=`pwd`
DOCKER_URL="$ACR".azurecr.io/mnistrepo/mnistmodel:latest
docker build . --no-cache  -f Dockerfile.model -t ${DOCKER_URL}
docker push ${DOCKER_URL}

# Follow instruction to set up training using local storage (pvc)
#  https://github.com/kubeflow/examples/tree/master/mnist#local-storage

pushd "${MNIST_ROOT}/training/local"
kustomize edit add configmap mnist-map-training --from-literal=name=mnist-train-local
kustomize edit set image training-image=$DOCKER_URL
# set 1 parameter server and 2 workers
../base/definition.sh --numPs 1 --numWorkers 2
# Set training parameters
kustomize edit add configmap mnist-map-training --from-literal=trainSteps=200
kustomize edit add configmap mnist-map-training --from-literal=batchSize=100
kustomize edit add configmap mnist-map-training --from-literal=learningRate=0.01

# Create storage class based on Azure File and pvc to store logs, checkpoint files and result model
cat <<EOF | k apply -f -
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: azurefile
provisioner: kubernetes.io/azure-file
mountOptions:
  - dir_mode=0777
  - file_mode=0777
  - uid=1000
  - gid=1000
  - mfsymlinks
  - nobrl
  - cache=none
parameters:
  skuName: Standard_LRS

^d

cat <<EOF | k apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: azure-file-for-ml
spec:
  accessModes:
  - ReadWriteMany
  storageClassName: azurefile
  resources:
    requests:
      storage: 10Gi

^d

# Configure the drive and path
PVC_NAME="azure-file-for-ml"
kustomize edit add configmap mnist-map-training --from-literal=pvcName=${PVC_NAME}
kustomize edit add configmap mnist-map-training --from-literal=pvcMountPath=/mnt
kustomize edit add configmap mnist-map-training --from-literal=modelDir=/mnt
kustomize edit add configmap mnist-map-training --from-literal=exportDir=/mnt/export


# to create a TFjobs crd
kustomize build . | k apply -f -
# To delete
# kustomize build . | k delete -f -

# Look at the TFJob crd and logs from the worker
k get tfjobs -o yaml 
k logs mnist-train-local-worker-0

# To see what the TFJobs operator did:
k logs po/$(kubectl get pods --selector=name=tf-job-operator --template '{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}')

popd

--------------------  DEPLOY TENSOR BOARD  -----
# Use local storage, follow this:
#   https://github.com/kubeflow/examples/tree/master/mnist#local-storage
pushd "${MNIST_ROOT}/monitoring/local"
kustomize edit add configmap mnist-map-monitoring --from-literal=pvcName=${PVC_NAME}
kustomize edit add configmap mnist-map-monitoring --from-literal=pvcMountPath=/mnt
kustomize edit add configmap mnist-map-monitoring --from-literal=logDir=/mnt
kustomize build . | kubectl apply -f -
kubectl port-forward service/tensorboard-tb 8090:80

popd

--------------------  SERVING   ----------------
#  https://github.com/kubeflow/examples/tree/master/mnist#local-storage-2
pushd "${MNIST_ROOT}/serving/local"
kustomize edit add configmap mnist-map-serving --from-literal=name=mnist-service-local
kustomize edit add configmap mnist-map-serving --from-literal=pvcName=${PVC_NAME}
kustomize edit add configmap mnist-map-serving --from-literal=pvcMountPath=/mnt
kustomize edit add configmap mnist-map-serving --from-literal=modelBasePath=/mnt/export
kustomize build . |kubectl apply -f -

kubectl describe deployments mnist-service-local
kubectl describe service mnist-service-local

# Deploy web UI
pushd "${MNIST_ROOT}/front"
kustomize build . |kubectl apply -f -
POD_NAME=$(kubectl get pods --selector=app=web-ui --template '{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}')
kubectl port-forward ${POD_NAME} 8070:5000 

# Check the image recognition result:
http://localhost:8070/?name=mnist&addr=mnist-service-local&port=9000


