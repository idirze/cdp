set -e

IMAGE_NAME="idirze/cldr-runner"
IMAGE_TAG="latest"
IMAGE_FULL_NAME=${IMAGE_NAME}:${IMAGE_TAG}

GITLAB_REPO="https://github.com/cloudera-labs"

# dir of script
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )";
# parent dir of that dir
PARENT_DIRECTORY="${DIR%/*}"
PROJECT_DIR=${1:-${PARENT_DIRECTORY}}
CONTAINER_NAME="cloudera-deploy-$(echo $PROJECT_DIR |md5 |awk '{print substr($0,0,5)}')"

log_info (){
   echo -e "[${CONTAINER_NAME}]-$(date) - $1"
}

ANSIBLE_COLLECTIONS_PATH="/opt/cldr-runner/collections"
ANSIBLE_ROLES_PATH="/opt/cldr-runner/roles"
CONTAINER_HOME_DIR="/home/runner"
# The playbooks are mounted there
CONTAINER_PROJECT_DIR="${CONTAINER_HOME_DIR}/project"

log_info "Checking if Docker is running..."
{ docker info >/dev/null 2>&1; echo "Docker OK"; } || { echo "Docker is required and does not seem to be running - please start Docker and retry" ; exit 1; }

docker pull ${IMAGE_NAME}:"${IMAGE_TAG}"

log_info "Ensuring default credential paths are available in calling using profile for mounting to execution environment"
for thisdir in  ".config/cloudera-deploy/profiles" ".cdp" "log"
do
  mkdir -p "${DIR}"/$thisdir
done

echo "Ensure Default profile is present"
/bin/cp -f "${DIR}/profile.yml" "${DIR}"/.config/cloudera-deploy/profiles/default

log_info "Mounting ${PROJECT_DIR} to container as Project Directory /runner/project"
log_info "Creating Container ${CONTAINER_NAME} from image ${IMAGE_FULL_NAME}"

if [ ! "$(docker ps -q -f name=${CONTAINER_NAME})" ]; then
    if [ "$(docker ps -aq -f status=exited -f name=${CONTAINER_NAME})" ]; then
        # cleanup if exited
        log_info "Attempting removal of exited execution container named '${CONTAINER_NAME}'"
        docker rm "${CONTAINER_NAME}" >/dev/null 2>&1 || echo "Execution container '${CONTAINER_NAME}' already removed, continuing..."
    fi
    # create new container if not running
    log_info "Creating new execution container named '${CONTAINER_NAME}'"
    docker run -td \
      --detach-keys="ctrl-@" \
      -v "${PROJECT_DIR}":"${CONTAINER_PROJECT_DIR}" \
      -v "$HOME/.ssh":"${CONTAINER_HOME_DIR}/.ssh" \
      -e ANSIBLE_LOG_PATH="${CONTAINER_PROJECT_DIR}/cloudera-deploy/log/${CONTAINER_NAME}-$(date +%F_%H%M%S)" \
      -e ANSIBLE_INVENTORY="inventory" \
      -e ANSIBLE_CALLBACK_WHITELIST="ansible.posix.profile_tasks" \
      -e ANSIBLE_GATHERING="smart" \
      -e ANSIBLE_DEPRECATION_WARNINGS=false \
      -e ANSIBLE_HOST_KEY_CHECKING=false \
      -e ANSIBLE_SSH_RETRIES=10 \
      -e ANSIBLE_COLLECTIONS_PATH="${ANSIBLE_COLLECTIONS_PATH}" \
      -e ANSIBLE_ROLES_PATH="${ANSIBLE_ROLES_PATH}" \
      --mount "type=bind,source=${DIR}/.config,target=${CONTAINER_HOME_DIR}/.config" \
      --mount "type=bind,source=${DIR}/.cdp,target=${CONTAINER_HOME_DIR}/.cdp" \
      --network="host" \
      --name "${CONTAINER_NAME}" \
      "${IMAGE_FULL_NAME}" \
      /usr/bin/env bash

    # Clone the repo locally if they are not there
    for project in cloudera-deploy cloudera.exe cloudera.cluster cloudera-runner
    do
      log_info "Installing the project $project into container location ${PROJECT_DIR}/${project}"
      if [ ! -d "${PROJECT_DIR}/${project}/.git" ]
      then
        echo "Please, clone the project ${project} first: git clone ${GITLAB_REPO}/${playbook}.git ${PROJECT_DIR}/${project} --depth 1"
      else
        log_info "\tThe project ${PROJECT_DIR}/${project} was already cloned locally, nothing to do!"
      fi
    done

fi

# Install/Update the cloudera local ansible collections
for collection in cloudera.exe cloudera.cluster
do
  log_info "Installing/Updating the collection ${CONTAINER_PROJECT_DIR}/$collection into container location ${ANSIBLE_COLLECTIONS_PATH}"
  docker exec -w /tmp -i "${CONTAINER_NAME}" sh -c \
    "rm -fr ${ANSIBLE_COLLECTIONS_PATH}/*/$(echo ${collection}| tr . /); \
    ansible-galaxy collection build -f ${CONTAINER_PROJECT_DIR}/${collection}; \
    ansible-galaxy collection install  $(echo ${collection}| tr . -)-*.tar.gz -p ${ANSIBLE_COLLECTIONS_PATH}; \
    rm -f $(echo ${collection}| tr . -)-*.tar.gz"
done 

echo "1- Add your ssh key of your host home directory to gitlab"
echo "2- Configure postgres db_server in cloudera-deploy/examples/sandbox/inventory_static.example and set default_database_port, default_database_password"

echo "Quickstart? Run this command -- ansible-playbook ${CONTAINER_PROJECT_DIR}/cloudera-deploy/main.yml -e \"definition_path=examples/sandbox\" -t run,default_cluster -i ${CONTAINER_PROJECT_DIR}/cloudera-deploy/examples/sandbox/inventory_static.ini"
docker exec \
  --workdir="${CONTAINER_PROJECT_DIR}" \
  --detach-keys="ctrl-@" \
  -it "${CONTAINER_NAME}" \
  /usr/bin/env bash


