--
-- LOGICALREP_AUDIT 1.0
-- Author: Yudisney Vazquez
-- Email: yvazquezo@gmail.com
--



-- DESCRIPTION

logicarep_audit is a PostgreSQL extension that allows you to get information and enable auditing for logical replication, allowing:
	- Generate de DDL of a publication.
	- Start the tracking of one or all publications in the database.
	- Reset the tracking of one or all publications in the database.
	- Stop the tracking of one or all publications in the database.
	- Generate de DDL of a subscription.
	- Start the tracking of one or all subscriptions in the database.
	- Reset the tracking of one or all subscriptions in the database.
	- Stop the tracking of one or all subscriptions in the database.


The extension creates a schema named logicalrep_audit to save tables and functions used for the auditing, and it has a function to connect to the publisher for check the replication slots.

As a result, logicalrep_audit creates two tables to save the publications or subscriptions structure alters.



-- INSTALLING LOGICALREP_AUDIT

In order to install the extension; first, copy the directory -composed by 4 files: logicalrep_audit.control, logicalrep_audit--1.0.sql, Makefile and Readme-, to compile it in the terminal and create the extension in the database publisher or subscriber; this can be done following the below steps:
	- In terminal:
		º cd /tmp/logicalrep_audit/
		º make
		º make install
	- In database:
		º CREATE EXTENSION logicalrep_audit;



-- TABLES AND FUNCTIONS

logicalrep_audit can create 2 tables and 15 functions that cover all the functionalities required to audit the logical replication in the database.

Has 2 tables for the audit:
	- publication_history: logs all the alters of tracked publications in the database.
	- subscription_history: logs all the alters of tracked subscriptions in the database.

Has 15 functions:
	- generate_ddl_publication(p_name name): generates the DDL of a publication passed by parameter.
	- track_publication(p_name name): track one publication passed by parameter, logs in publication_history all alters query of the publication.
	- track_all_publications(): track all publications in the database, logs in publication_history all alters query of the publications existing in the database.
	- reset_publication_tracking(p_name name): reset the publication history for one publication passed by parameter.
	- reset_all_publications_tracking(): reset the publication history for all publications in the database.
	- stop_publication_tracking(p_name name): stop the tracking of one publication passed by parameter.
	- stop_all_publications_tracking(): stop the tracking of all publications existing in the database.
	- connection_to_publisher(p_name name): stablishs a connection with the publisher to check that a replication slot was created.
	- generate_ddl_subscription(p_name name): generates the DDL of a subscription passed by parameter.
	- track_subscription(p_name name): track one subscription passed by parameter, logs in subscription_history all alters query of the subscription.
	- track_all_subscriptions(): track all subscriptions in the database, logs in subscription_history all alters query of the subscriptions in the database.
	- reset_subscription_tracking(p_name name): reset the subscription history for one subscription passed by parameter.
	- reset_all_subscriptions_tracking(): reset the subscription history for all subscriptions in the database.
	- stop_subscription_tracking(p_name name): stop the tracking of one subscription passed by parameter.
	- stop_all_subscriptions_tracking(): stop the tracking of all subscriptions existing in the database.



-- REMOVING LOGICALREP_AUDIT

Removing the extension can be done following the below step:
	- In database:
		º DROP EXTENSION logicalrep_audit CASCADE;
