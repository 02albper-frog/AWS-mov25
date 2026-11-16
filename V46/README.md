# V46 – IaC med CloudFormation

**Kurs:** Amazon Web Services · **Vecka:** 46 · **Uppgift:** 5 av 8 · **Företag:** Novatrix AB

> Arbetsversion. Den fullständiga dokumentationen med skärmdumpar läggs till när lösningen är testad.

Hela WordPress-stacken från v42–v45 (nätverk, IAM, databas, lagring och servrar) definieras
som CloudFormation-templates och byggs från repot med ett kommando. Backup-bucketen ligger i
en egen stack som aldrig rivs, så att webbplatsen kan återställas efter en ny uppbyggnad.

## Stackar

| Stack | Template | Innehåll |
|-------|----------|----------|
| `novatrix-backup` | `templates/01-backup.yaml` | Backup-bucket (`DeletionPolicy: Retain`), livscykel, kryptering |
| `novatrix-iam` | `templates/02-iam.yaml` | Webbserverns roll, grupper och användare |
| `novatrix-network` | `templates/03-network.yaml` | VPC, subnät, routing, NACL:er, security groups |
| `novatrix-data` | `templates/04-data.yaml` | Lösenord (Secrets Manager), RDS Multi-AZ, EFS |
| `novatrix-app` | `templates/05-app.yaml` | Bastion och webbserver med WordPress |

## Återskapa miljön

Förutsättningar: AWS CLI v2 inloggat med `aws login` som administratör, nyckelparet
`novatrix-key` i eu-north-1 med privat nyckel i `~/.ssh/novatrix-key.pem`, Git Bash eller
terminal, och ett eget globalt unikt `BackupBucketName` i `parameters/prod.env`.

```bash
git clone https://github.com/02albper-frog/AWS-mov25.git
cd AWS-mov25/V46
./deploy.sh               # bygger alla fem stackar (20-30 minuter)
./install-wordpress.sh    # databasanvändare och WordPress
./restore-wordpress.sh    # valfritt: återställ databas och bilder från senaste backupen
./verify.sh               # testar hela stacken

./backup-now.sh           # tar en backup direkt
./preview-change.sh data  # förhandsgranskar en ändring i en template
./destroy.sh              # tar en sista backup och river allt utom backup-stacken
```
