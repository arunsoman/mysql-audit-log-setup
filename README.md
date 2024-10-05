# MySQL Audit Log Setup Script

This repository contains a Bash script (`setup_audit_logs.sh`) designed to create audit log tables and triggers for specified MySQL tables. It enables database administrators to track changes (inserts, updates, deletes) in MySQL databases, aiding in data auditing and compliance.

## Features

- **Automated Audit Log Creation:** Creates audit log tables and triggers for the specified MySQL tables.
- **Supports MySQL 8.0+:** Leverages JSON data types and modern MySQL features.
- **Secure Input:** Prompts for secure user input for MySQL credentials.
- **Pagination for Table Selection:** Displays available tables in pages for easier navigation.
- **Comprehensive Logging:** Redirects logs to a file for later review.
- **Handles Insert, Update, Delete Events:** Tracks all crucial data changes in the selected tables.
- **Configurable:** Supports customization, such as changing log file paths and setting page sizes.

## Prerequisites

- **MySQL 8.0+**
- **Bash Shell**
- MySQL user with sufficient privileges to create tables and triggers.

## Getting Started

### Clone the Repository

```bash
git clone https://github.com/your-username/mysql-audit-log-setup.git
cd mysql-audit-log-setup
