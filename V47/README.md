# V47 – Skalbarhet och tillgänglighet

**Kurs:** Amazon Web Services · **Vecka:** 47 · **Uppgift:** 6 av 8 · **Företag:** Novatrix AB

> Arbetsversion. Den fullständiga dokumentationen med skärmdumpar läggs till när lösningen är testad.

WordPress-stacken från v46 görs skalbar och högtillgänglig: en Application Load Balancer
fördelar trafiken till en Auto Scaling-grupp med 2–4 webbservrar i två tillgänglighetszoner.
Allt, inklusive launch template, grupp, skalningsregel och lastbalanserare, är CloudFormation.

## Stackar

| Stack | Template | Innehåll |
|-------|----------|----------|
| `novatrix-backup` | `templates/01-backup.yaml` | Backup-bucket (`DeletionPolicy: Retain`) |
| `novatrix-iam` | `templates/02-iam.yaml` | Webbservrarnas roll, grupper och användare |
| `novatrix-network` | `templates/03-network.yaml` | VPC, publika subnät i två zoner, privata subnät, NACL:er, security groups |
| `novatrix-data` | `templates/04-data.yaml` | Lösenord och WordPress-nycklar, RDS (single-AZ), EFS |
| `novatrix-app` | `templates/05-app.yaml` | Bastion, launch template, Auto Scaling-grupp, lastbalanserare |

## Köra lösningen

```bash
cd V47
./deploy.sh                    # bygger alla stackar (20-30 minuter)
./install-wordpress.sh         # en gång; gäller alla servrar
./verify.sh                    # 34 tester
./test-availability.sh krasch  # stoppar Apache på en server och följer självläkningen
./test-availability.sh avsluta # tar bort en server och följer ersättningen
./load-test.sh start           # belastar CPU och visar hur gruppen skalar ut
./destroy.sh                   # sista backup, river allt utom backup-stacken
```
