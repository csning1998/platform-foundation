
output "secret_name" {
  description = "Name of the Secret which contains tls.crt, tls.key, and ca.crt."
  value       = kubernetes_manifest.certificate.manifest.spec.secretName
}

output "namespace" {
  description = "Namespace of the Certificate and the Secret."
  value       = kubernetes_manifest.certificate.manifest.metadata.namespace
}
