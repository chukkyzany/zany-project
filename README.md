# zany-project: 3-Tier E-Commerce App on AWS

A small e-commerce web app (products, cart, guest checkout) deployed on AWS using a classic 3-tier architecture. The app server and the database sit in **private subnets**, and the only public entry point is an **Application Load Balancer**. Everything was built by hand in the AWS Console.

![Store homepage](screenshots/01-store-homepage.png)

## Architecture

```
Internet
   |
   v
Application Load Balancer (public subnets, 2 AZs)
   |  HTTP :80
   v
EC2 - Ubuntu 24.04, Apache + PHP (private subnet)
   |  MySQL :3306 (SSL, verified)
   v
RDS MySQL (private subnets, not publicly accessible)
```

| Layer | Service | Notes |
|---|---|---|
| Network | VPC `10.0.0.0/16` | 2 public + 2 private subnets across 2 Availability Zones |
| Outbound access | NAT Gateway | Lets the private EC2 install packages |
| AWS service access | S3 Gateway endpoint | Free, private route to S3 from the private subnets |
| Entry point | Application Load Balancer | Internet-facing, health check on `/health.html` |
| App server | EC2 (Ubuntu Server 24.04 LTS) | Private subnet, no public IP, no SSH key pair |
| Admin access | AWS Systems Manager Session Manager | Shell access with no open SSH port |
| Database | RDS MySQL | Private subnets, public access disabled |

![VPC resource map](/screenshots/07-resource-map.png)

## Security design

Security groups are chained so each layer only accepts traffic from the layer in front of it:

| Security group | Inbound rule |
|---|---|
| `eshop-alb-sg` | HTTP 80 from the internet |
| `eshop-app-sg` | HTTP 80 from `eshop-alb-sg` only |
| `eshop-db-sg` | MySQL 3306 from `eshop-app-sg` only |

Other choices:
- **No SSH.** The EC2 has no key pair and no public IP. Access is through Session Manager using an IAM role with `AmazonSSMManagedInstanceCore`.
- **Database not public.** RDS is only reachable from the app server.
- **Encrypted, verified connection.** The app connects to RDS over SSL and verifies the server certificate using the AWS RDS CA bundle.
- **Credentials outside the web root.** The database login is stored in `/var/www/private/config.php`, readable only by root and the web server group, and is never committed to this repository.
- **Safe database access in code.** All queries use PDO prepared statements, and output is HTML-escaped.

![Security groups](/screenshots/05-security-group.png)
![RDS not publicly accessible](/screenshots/ 04-rds-database.png)

## The app

- **Products page:** lists products from the database with an add-to-cart button
- **Cart:** session-based, with quantity updates and item removal
- **Guest checkout:** name and email, no accounts
- **Orders:** saved to RDS in a single transaction that also checks and reduces stock
- **Confirmation page:** shows the order number and total

Database tables: `products`, `orders`, `order_items`.

![Order confirmation](/screenshots/03-orders.png)

## How it was built

1. **VPC and subnets:** created the VPC, two public and two private subnets across two AZs, an internet gateway, a NAT gateway, and separate public and private route tables.
2. **S3 gateway endpoint:** attached to the private route tables.
3. **Security groups:** created the three chained groups above.
4. **RDS MySQL:** created a DB subnet group from the two private subnets, then the database with public access off and `eshop-db-sg` attached.
5. **EC2:** launched Ubuntu Server 24.04 in a private subnet with the SSM role and no key pair. [`userdata.sh`](userdata.sh) installs Apache, PHP and the MySQL client and adds a health check page.
6. **Database tables:** connected from the EC2 through Session Manager and created the schema and sample products.
7. **App deployment:** [`deploy-app.sh`](deploy-app.sh) asks for the database endpoint and login, then creates the PHP app on the server.
8. **Load balancer:** created the target group (health check `/health.html`), registered the EC2, and created the ALB with an HTTP listener forwarding to it.
9. **Testing:** browsed the store through the ALB address and completed a full order from cart to confirmation.

![Target group healthy](/screenshots/06-target-group.png)

## Troubleshooting notes

- **Permission denied downloading the RDS certificate:** Session Manager starts in a folder the user can't write to. Downloading to `/tmp` fixed it.
- **`SSL_CTX_set_default_verify_paths failed`:** caused by the missing certificate file above. Once the file was in place, verified SSL worked.
- **Private instance needs internet for `apt`:** solved with the NAT gateway and a private route table pointing `0.0.0.0/0` to it.

## Repository contents

| File | Purpose |
|---|---|
| `userdata.sh` | EC2 user data: installs Apache, PHP and the MySQL client |
| `deploy-app.sh` | Creates the PHP application on the server and connects it to RDS |
| `docs/screenshots/` | Console screenshots referenced in this README |

## Cost and cleanup

The NAT gateway, the load balancer and the RDS instance all cost money while they run. After taking screenshots, delete them to avoid charges: ALB and target group, NAT gateway (and release its Elastic IP), RDS database, EC2 instance, and finally the VPC.

## Possible improvements

- Add a second EC2 in the other AZ for high availability
- Add HTTPS to the load balancer with an ACM certificate
- Rebuild the infrastructure with Terraform
- Store the database password in AWS Secrets Manager
- Add user accounts and a real payment flow

## What I learned

How to design a multi-tier network with public and private subnets, chain security groups for least-privilege access, reach private instances without SSH, connect to RDS securely, and debug problems across the network, server and application layers.
