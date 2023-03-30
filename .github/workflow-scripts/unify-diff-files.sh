#!/bin/bash

declare -a deploymentFiles

while getopts "f:t:o:" opt; do
    case "${opt}" in
        f) files=($OPTARG);;
        t) type=$OPTARG;;
        o) output=$OPTARG;;
        *) return 1;;
    esac
done

parent-find() {
    local file="$1"
    local dir="${2:-$PWD}"
    test -e "$dir/$file" && echo "$dir" && return 0
    [ '/' = "$dir" ] && return 1
    parent-find "$file" "$(dirname "$dir")"
}

for i in "${files[@]}"
do
    if [[ "$type" == "helm" ]];
    then
        deploymentFiles+=($(parent-find Chart.yaml $i))
    else
        deploymentFiles+=($(parent-find kustomization.yaml $i))
    fi
done
sorted_unique_ids=($(echo "${deploymentFiles[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
json_stringified=$(jq -n -c '$ARGS.positional' --args "${sorted_unique_ids[@]}")
echo "$output=$json_stringified" >> "$GITHUB_OUTPUT"
