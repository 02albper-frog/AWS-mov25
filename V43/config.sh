#!/bin/bash
# Gemensamma inställningar för V43-skripten.
# BUCKET måste vara globalt unikt i hela AWS (små bokstäver, siffror, bindestreck).

REGION=eu-north-1
BUCKET=novatrix-web-02albper

# EC2 (samma som v42)
KEY_NAME=novatrix-key
TAG_NAME=novatrix-web
SG_NAME=novatrix-web-sg

# IAM
ROLE_NAME=novatrix-web-ec2-role
PROFILE_NAME=novatrix-web-ec2-profile
DEV_GROUP=novatrix-utveckling
OPS_GROUP=novatrix-drift
DEV_USER=anna-dev
OPS_USER=erik-drift
DEV_POLICY=novatrix-utveckling-policy
OPS_POLICY=novatrix-drift-policy
ROLE_POLICY=novatrix-web-ec2-policy