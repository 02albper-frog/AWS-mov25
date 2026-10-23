# V43 – IAM och identitet

Behörighetslösning för Novatrix AB enligt least privilege: grupper för utveckling och
drift, samt en IAM-roll som låter webbservern (EC2) läsa från och skriva till S3.

## Köra lösningen

Kör i Git Bash som administratör:

```bash
cd V43
./setup-iam.sh      # bucket, policies, grupper, användare och roll
./verify-iam.sh     # testar behörigheterna
./provision.sh      # startar webbservern med rollen
./teardown.sh       # tar bort instans och security group
./teardown-iam.sh   # tar bort IAM-resurser och bucket
```


