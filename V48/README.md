# V48 – Monitorering och cloud native

**Kurs:** Amazon Web Services · **Vecka:** 48 · **Uppgift:** 7 av 8 · **Företag:** Novatrix AB

> Arbetsversion. Den fullständiga dokumentationen med skärmdumpar läggs till när lösningen är testad.

Den skalbara WordPress-lösningen från v47 får central övervakning i CloudWatch:
CloudWatch-agenten på varje webbserver skickar minne, disk och loggar, larmen tittar på
hela gruppen och skickar e-post via SNS, och dashboarden `novatrix-drift` visar om Novatrix
mår bra. Lambda-funktionen `novatrix-sajtkoll` frågar sajten utifrån var 5:e minut.
Allt är CloudFormation.

## Stackar

| Stack | Template | Innehåll |
|-------|----------|----------|
| `novatrix-backup` | `templates/01-backup.yaml` | Backup-bucket (`DeletionPolicy: Retain`) |
| `novatrix-iam` | `templates/02-iam.yaml` | Webbrollen (nu med `CloudWatchAgentServerPolicy`), grupper och användare |
| `novatrix-network` | `templates/03-network.yaml` | VPC, subnät i två zoner, NACL:er, security groups |
| `novatrix-data` | `templates/04-data.yaml` | Lösenord och WordPress-nycklar, RDS (single-AZ), EFS |
| `novatrix-app` | `templates/05-app.yaml` | Bastion, lastbalanserare, Auto Scaling-grupp, agentens konfiguration och log groups |
| `novatrix-monitoring` | `templates/06-monitoring.yaml` | SNS `novatrix-larm`, 8 larm, dashboard, sparade sökningar, Lambda `novatrix-sajtkoll` |

## Förberedelse: e-postadressen för larmen

Adressen ligger i en lokal fil som inte kommer med till GitHub:

```bash
cp parameters/prod.local.env.example parameters/prod.local.env
# öppna filen och skriv in din adress efter AlarmEmail=
```

## Köra lösningen

```bash
cd V48
./deploy.sh                       # bygger alla sex stackar, bekräfta sedan mailet från AWS
./install-wordpress.sh            # eller ./restore-wordpress.sh
./verify.sh                       # alla tester, inklusive övervakningen
./stress-test.sh larmtest         # testar larmkedjan larm -> SNS -> e-post
./load-test.sh start              # CPU-larmet och skalningen
./stress-test.sh minne            # minneslarmet
./stress-test.sh disk             # disklarmet
./stress-test.sh unhealthy        # larmet för sjuka servrar
./stress-test.sh stopp            # återställer efter testerna
./destroy.sh                      # sista backup, river allt utom backup-stacken
```
