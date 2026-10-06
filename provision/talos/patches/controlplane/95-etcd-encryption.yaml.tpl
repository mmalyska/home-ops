# What:   Kubernetes secrets encryption at rest in etcd: one secretbox key, with the identity provider as fallback
# Why:    Replaces cluster.secretboxEncryptionSecret with the same secret (TALHELPER_AESCBCENCYPTIONKEY, also in
#         secrets.yaml.tpl) and the key name and provider order the cluster already runs. The key name is part of every
#         stored ciphertext, so it is written out here instead of taken from a generated default: never rename key2
# Nodes:  control plane
# Apply:  live
apiVersion: v1alpha1
kind: KubeEtcdEncryptionConfig
config:
  resources:
    - providers:
        - secretbox:
            keys:
              - name: key2
                secret: ${TALHELPER_AESCBCENCYPTIONKEY}
        - identity: {}
      resources:
        - secrets
