# V45 – Storage och databas

**Kurs:** Amazon Web Services · **Vecka:** 45 · **Uppgift:** 4 av 8 · **Företag:** Novatrix AB

> Arbetsversion. Den fullständiga dokumentationen med skärmdumpar läggs till när lösningen är testad.

WordPress på EC2 med databasen i RDS MariaDB (Multi-AZ), filerna i EFS och nattliga
databasbackuper i en privat S3-bucket som rensas efter 14 dagar. Allt byggs som kod.

## Köra lösningen

```bash
cd V45
./setup-iam.sh          # IAM och webb-bucket
./verify-iam.sh         # testar IAM
./network.sh            # VPC, subnät, NACL:er och security groups
./storage.sh            # lösenord, backup-bucket, EFS och RDS
./provision.sh          # bastion och webbserver
./install-wordpress.sh  # databasanvändare, WordPress och första backupen
./verify-network.sh     # testar nätverket
./verify-wordpress.sh   # testar databas, lagring, backup och WordPress

./teardown.sh           # servrarna
./teardown-storage.sh   # RDS, EFS, backup-bucket och lösenord
./teardown-network.sh   # nätverket
./teardown-iam.sh       # IAM och webb-bucket
```
