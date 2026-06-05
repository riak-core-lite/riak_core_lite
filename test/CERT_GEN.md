# Generating test certs for unit tests

```sh
$ openssl genrsa -out ca.key 4096
$ openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -out ca.crt -config ca_san.cnf
$ openssl genrsa -out site1.key 4096
$ openssl genrsa -out site2.key 4096
$ openssl req -new -key site1.key -out site1.csr -config csr_san_site_1.cnf
$ openssl req -new -key site2.key -out site2.csr -config csr_san_site_2.cnf
$ openssl x509 -req -in site1.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out site1.crt -days 3650 -sha256 -extfile sign_ext_1.cnf
$ openssl x509 -req -in site2.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out site2.crt -days 3650 -sha256 -extfile sign_ext_2.cnf
```
