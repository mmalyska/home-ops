{{- define "honcho.llmEnv" -}}
- name: DB_USER
  valueFrom:
    secretKeyRef:
      name: honchodb-cnpg-app
      key: username
- name: DB_PASS
  valueFrom:
    secretKeyRef:
      name: honchodb-cnpg-app
      key: password
- name: DB_CONNECTION_URI
  value: "postgresql+psycopg://$(DB_USER):$(DB_PASS)@honchodb-cnpg-rw.honcho.svc.cluster.local:5432/app"
- name: AUTH_USE_AUTH
  value: "false"
- name: SENTRY_ENABLED
  value: "false"
- name: CACHE_ENABLED
  value: "false"
- name: LLM_OPENAI_API_KEY
  valueFrom:
    secretKeyRef:
      name: honcho-secrets
      key: HONCHO_OPENROUTER_API_KEY
- name: DERIVER_MODEL_CONFIG__TRANSPORT
  value: openai
- name: DERIVER_MODEL_CONFIG__MODEL
  value: google/gemini-flash-1.5
- name: DERIVER_MODEL_CONFIG__OVERRIDES__BASE_URL
  value: https://openrouter.ai/api/v1
- name: SUMMARY_MODEL_CONFIG__TRANSPORT
  value: openai
- name: SUMMARY_MODEL_CONFIG__MODEL
  value: google/gemini-flash-1.5
- name: SUMMARY_MODEL_CONFIG__OVERRIDES__BASE_URL
  value: https://openrouter.ai/api/v1
- name: EMBEDDING_MODEL_CONFIG__TRANSPORT
  value: openai
- name: EMBEDDING_MODEL_CONFIG__MODEL
  value: openai/text-embedding-3-small
- name: EMBEDDING_MODEL_CONFIG__OVERRIDES__BASE_URL
  value: https://openrouter.ai/api/v1
- name: DIALECTIC_LEVELS__minimal__MODEL_CONFIG__TRANSPORT
  value: openai
- name: DIALECTIC_LEVELS__minimal__MODEL_CONFIG__MODEL
  value: google/gemini-flash-1.5
- name: DIALECTIC_LEVELS__minimal__MODEL_CONFIG__OVERRIDES__BASE_URL
  value: https://openrouter.ai/api/v1
- name: DIALECTIC_LEVELS__low__MODEL_CONFIG__TRANSPORT
  value: openai
- name: DIALECTIC_LEVELS__low__MODEL_CONFIG__MODEL
  value: google/gemini-flash-1.5
- name: DIALECTIC_LEVELS__low__MODEL_CONFIG__OVERRIDES__BASE_URL
  value: https://openrouter.ai/api/v1
- name: DIALECTIC_LEVELS__medium__MODEL_CONFIG__TRANSPORT
  value: openai
- name: DIALECTIC_LEVELS__medium__MODEL_CONFIG__MODEL
  value: google/gemini-2.0-flash
- name: DIALECTIC_LEVELS__medium__MODEL_CONFIG__OVERRIDES__BASE_URL
  value: https://openrouter.ai/api/v1
- name: DIALECTIC_LEVELS__high__MODEL_CONFIG__TRANSPORT
  value: openai
- name: DIALECTIC_LEVELS__high__MODEL_CONFIG__MODEL
  value: anthropic/claude-3-5-haiku
- name: DIALECTIC_LEVELS__high__MODEL_CONFIG__OVERRIDES__BASE_URL
  value: https://openrouter.ai/api/v1
- name: DIALECTIC_LEVELS__max__MODEL_CONFIG__TRANSPORT
  value: openai
- name: DIALECTIC_LEVELS__max__MODEL_CONFIG__MODEL
  value: anthropic/claude-3-5-sonnet
- name: DIALECTIC_LEVELS__max__MODEL_CONFIG__OVERRIDES__BASE_URL
  value: https://openrouter.ai/api/v1
- name: DREAM_DEDUCTION_MODEL_CONFIG__TRANSPORT
  value: openai
- name: DREAM_DEDUCTION_MODEL_CONFIG__MODEL
  value: google/gemini-flash-1.5
- name: DREAM_DEDUCTION_MODEL_CONFIG__OVERRIDES__BASE_URL
  value: https://openrouter.ai/api/v1
- name: DREAM_INDUCTION_MODEL_CONFIG__TRANSPORT
  value: openai
- name: DREAM_INDUCTION_MODEL_CONFIG__MODEL
  value: google/gemini-flash-1.5
- name: DREAM_INDUCTION_MODEL_CONFIG__OVERRIDES__BASE_URL
  value: https://openrouter.ai/api/v1
{{- end -}}
