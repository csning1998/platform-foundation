
# The KVM default OUI prefix 52:54:00 precedes the first 6 hexadecimal characters of the MD5 digest of each seed.
output "macs" {
  description = "Locally administered MAC addresses keyed as the seeds."
  value = {
    for key, seed in var.seeds : key => format("52:54:00:%s:%s:%s",
      substr(md5(seed), 0, 2),
      substr(md5(seed), 2, 2),
      substr(md5(seed), 4, 2)
    )
  }
}
