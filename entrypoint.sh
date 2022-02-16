#!/bin/sh
set -e

function main() {
  echo "" # see https://github.com/actions/toolkit/issues/168

  sanitize "${INPUT_NAME}" "name"
  sanitize "${INPUT_USERNAME}" "username"
  sanitize "${INPUT_PASSWORD}" "password"

  REGISTRY_NO_PROTOCOL=$(echo "${INPUT_REGISTRY}" | sed -e 's/^https:\/\///g')
  if uses "${INPUT_REGISTRY}" && ! isPartOfTheName "${REGISTRY_NO_PROTOCOL}"; then
    INPUT_NAME="${REGISTRY_NO_PROTOCOL}/${INPUT_NAME}"
  fi

  translateDockerTag
  DOCKERNAME="${INPUT_NAME}:${TAG}"

  # check if we should do anything at all with this branch
  if { [ -z ${PUSH_BRANCH_TO_DOCKERHUB} ] || [ "${PUSH_BRANCH_TO_DOCKERHUB}" = "false" ]; } && [ "${TAG}" != "develop" ] && [ "${TAG}" != "develop-1.0" ] && [ "${TAG}" != "develop-2.0" ] && [ "${TAG}" != "master" ] && [ "${TAG}" != "main" ] &&  ! isReleaseBranch && ! isGitTag ; then
    echo "workflow environment PUSH_BRANCH_TO_DOCKERHUB is false or not set and this is no default branch -> stopping push gracefully -> no error"
    exit 0;
  fi

  if uses "${INPUT_WORKDIR}"; then
    changeWorkingDirectory
  fi

  echo ${INPUT_PASSWORD} | docker login -u ${INPUT_USERNAME} --password-stdin ${INPUT_REGISTRY}

  BUILDPARAMS=""

  if uses "${INPUT_DOCKERFILE}"; then
    useCustomDockerfile
  fi
  if uses "${INPUT_BUILDARGS}"; then
    addBuildArgs
  fi
  if uses "${INPUT_BUILDTARGET}"; then
    useBuildTarget
  fi
  if usesBoolean "${INPUT_CACHE}"; then
    useBuildCache
  fi

  if usesBoolean "${INPUT_SNAPSHOT}"; then
    pushWithSnapshot
  else
    pushWithoutSnapshot
  fi
  echo ::set-output name=tag::"${TAG}"

  docker logout
}

function sanitize() {
  if [ -z "${1}" ]; then
    >&2 echo "Unable to find the ${2}. Did you set with.${2}?"
    exit 1
  fi
}

function isPartOfTheName() {
  [ $(echo "${INPUT_NAME}" | sed -e "s/${1}//g") != "${INPUT_NAME}" ]
}

function translateDockerTag() {
  local BRANCH=$(echo ${GITHUB_REF} | sed -e "s/refs\/heads\///g" | sed -e "s/\//-/g" | sed -e 's/[^ -~]//g')
  if hasCustomTag; then
    TAG=$(echo ${INPUT_NAME} | cut -d':' -f2)
    INPUT_NAME=$(echo ${INPUT_NAME} | cut -d':' -f1)
  elif isOnDefaultBranch; then
    TAG="latest"
  elif isGitTag && usesBoolean "${INPUT_TAG_NAMES}"; then
    TAG=$(echo ${GITHUB_REF} | sed -e "s/refs\/tags\///g")
  elif isGitTag; then
    TAG="latest"
  elif isPullRequest; then
    TAG="${GITHUB_SHA}"
  elif isReleaseBranch; then
    TAG=$(echo "${GITHUB_REF}-rc" | sed -e "s/refs\/heads\/release\///g")
  else
    TAG="${BRANCH}"
  fi;
}

function hasCustomTag() {
  [ $(echo "${INPUT_NAME}" | sed -e "s/://g") != "${INPUT_NAME}" ]
}

isOnDefaultBranch() {
  if uses "${INPUT_DEFAULT_BRANCH}"; then
    [ "${BRANCH}" = "${INPUT_DEFAULT_BRANCH}" ]
  else
    [ "${BRANCH}" = "master" ] || [ "${BRANCH}" = "main" ]
  fi
}

function isGitTag() {
  [ $(echo "${GITHUB_REF}" | sed -e "s/refs\/tags\///g") != "${GITHUB_REF}" ]
}

function isPullRequest() {
  [ $(echo "${GITHUB_REF}" | sed -e "s/refs\/pull\///g") != "${GITHUB_REF}" ]
}

function isReleaseBranch() {
  [ $(echo "${GITHUB_REF}" | sed -e "s/refs\/heads\/release\///g") != "${GITHUB_REF}" ]
}

function changeWorkingDirectory() {
  cd "${INPUT_WORKDIR}"
}

function useCustomDockerfile() {
  BUILDPARAMS="$BUILDPARAMS -f ${INPUT_DOCKERFILE}"
}

function addBuildArgs() {
  for arg in $(echo "${INPUT_BUILDARGS}" | tr ',' '\n'); do
    BUILDPARAMS="$BUILDPARAMS --build-arg ${arg}"
    echo "::add-mask::${arg}"
  done
}

function useBuildCache() {
  if docker pull ${DOCKERNAME} 2>/dev/null; then
    BUILDPARAMS="$BUILDPARAMS --cache-from ${DOCKERNAME}"
  fi
}

function useBuildTarget() {
  BUILDPARAMS="$BUILDPARAMS --target=${INPUT_BUILDTARGET}"
}

function uses() {
  [ ! -z "${1}" ]
}

function usesBoolean() {
  [ ! -z "${1}" ] && [ "${1}" = "true" ]
}

function pushWithSnapshot() {
  local TIMESTAMP=`date +%Y%m%d%H%M%S`
  local SHORT_SHA=$(echo "${GITHUB_SHA}" | cut -c1-6)
  local SNAPSHOT_TAG="${TIMESTAMP}${SHORT_SHA}"
  local SHA_DOCKER_NAME="${INPUT_NAME}:${SNAPSHOT_TAG}"
  docker build $BUILDPARAMS -t ${DOCKERNAME} -t ${SHA_DOCKER_NAME} .
  docker push ${DOCKERNAME}
  docker push ${SHA_DOCKER_NAME}
  echo ::set-output name=snapshot-tag::"${SNAPSHOT_TAG}"
}

function pushWithoutSnapshot() {
  docker build $BUILDPARAMS -t ${DOCKERNAME} .
  docker push ${DOCKERNAME}
}

main
