# logicalrep_audit
*PostgreSQL extension that allows you to get information and enable auditing for logical replication*

###### Version: 1.0 | Author: Yudisney Vazquez (yvazquezo@gmail.com)

## Description
logicalrep_audit is a PostgreSQL extension that allows you to get information and enable auditing for logical replication, allowing:
* Generate de DDL of a publication/subscription.
* Start the tracking of one or all publications/subscriptions in the database.
* Reset the tracking of one or all publications/subscriptions in the database.
* Stop the tracking of one or all publications/subscriptions in the database.

The extension creates a schema named logicalrep_audit to save tables and functions used for auditing, and it has a function to connect to the publisher for check the replication slots, so, is needed the postgres_fdw.

As a result, logicalrep_audit creates two tables to save the publications or subscriptions structure alters.

## Requeriment
To check if the replication slots are created in the publisher, the extension uses postgres_fdw, so, it must be installed the contrib package for the correct use of logicalrep_audit.

## Installing logicalrep_audit
In order to install the extension; first, copy the directory -composed by 4 files: logicalrep_audit.control, logicalrep_audit--1.0.sql, Makefile and Readme-, to compile it in the terminal and create the extension in the database publisher or subscriber; this can be done following the below steps:
* In terminal:
  * cd /tmp/logicalrep_audit/
  * make
  * make install
* In database:
  * CREATE EXTENSION logicalrep_audit;

### Installing logicalrep_audit on RDS or databases as a service
To install the extension on AWS RDS or databases as a service the following step can be performed:
* Execute on the database the commands of logicalrep_audit--1.0.sql file.

## Functionalities
logicalrep_audit can create 2 tables and 15 functions that cover all the functionalities required to audit the logical replication in the database.

The extension has 2 tables for audit:
* publication_history: logs all the alters of tracked publications in the database.
* subscription_history: logs all the alters of tracked subscriptions in the database.

The extension has 15 functions:
* generate_ddl_publication(p_name name): generates the DDL of a publication passed by parameter.
* track_publication(p_name name): track one publication passed by parameter, logs in publication_history all alters query of the publication.
* track_all_publications(): track all publications in the database, logs in publication_history all alters query of the publications existing in the database.
* reset_publication_tracking(p_name name): reset the publication history for one publication passed by parameter.
* reset_all_publications_tracking(): reset the publication history for all publications in the database.
* stop_publication_tracking(p_name name): stop the tracking of one publication passed by parameter.
* stop_all_publications_tracking(): stop the tracking of all publications existing in the database.
* connection_to_publisher(p_name name): stablishs a connection with the publisher to check that a replication slot was created.
* generate_ddl_subscription(p_name name): generates the DDL of a subscription passed by parameter.
* track_subscription(p_name name): track one subscription passed by parameter, logs in subscription_history all alters query of the subscription.
* track_all_subscriptions(): track all subscriptions in the database, logs in subscription_history all alters query of the subscriptions in the database.
* reset_subscription_tracking(p_name name): reset the subscription history for one subscription passed by parameter.
* reset_all_subscriptions_tracking(): reset the subscription history for all subscriptions in the database.
* stop_subscription_tracking(p_name name): stop the tracking of one subscription passed by parameter.
* stop_all_subscriptions_tracking(): stop the tracking of all subscriptions existing in the database.

## Removing logicalrep_audit
Removing the extension can be done following the below step:
* In database:
  * DROP EXTENSION logicalrep_audit CASCADE;

## Examples
To use the functionalities of logicalrep_audit, the extension must be created in the database:

#### Create the extension on dell database
    dell=# create extension logicalrep_audit ;
    CREATE EXTENSION

#### Generate the DDL of a publication
The function "generate_ddl_publication" generates the DDL of the publication passed by parameter, with the tables included in the publication and the publication options:

##### Create a publication on dell database
     dell=# create publication pub_categories for table categories;
     CREATE PUBLICATION

##### Generate the DDL of pub_categories
     dell=# select * from logicalrep_audit.generate_ddl_publication('pub_categories');
                                                                     generate_ddl_publication                                                                 
     ---------------------------------------------------------------------------------------------------------------------------------------------------------
      CREATE PUBLICATION pub_categories FOR TABLE public.categories WITH (publish = 'insert, update, delete, truncate', publish_via_partition_root = false);
     (1 line)

#### Generate the DDL of a subscription
The function "generate_ddl_subscription" generates the DDL of the subscription passed by parameter, with the subscription options:

##### Create a subscription on dell_rds database
     dell_rds=# create subscription sub_categories connection 'host=192.168.0.31 port=5432 dbname=dell user=postgres password=postgres' publication pub_categories;
     NOTICE:  created replication slot « sub_categories » on publisher
     CREATE SUBSCRIPTION

##### Generate the DDL of sub_categories
     dell_rds=# select * from logicalrep_audit.generate_ddl_subscription('sub_categories');
                                                                     generate_ddl_subscription                                                                                                                               
     ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
      CREATE SUBSCRIPTION sub_categories CONNECTION 'host=localhost port=5432 dbname=dell user=postgres password=postgres' PUBLICATION pub_categories WITH (connect = true, enabled = true, copy_data = true, create_slot = true, slot_name = sub_categories, synchronous_commit = 'off');
     (1 line)

#### Start the tracking of one publication
Start tracking of one publication logs on table publication_history all the changes made to the structure of the publication, logging:
* pub_oid: identifier of the publication.
* pub_name: name of the publication.
* pub_database: database where the publication exists.
* pub_action: the action in the publication:
  * Start Tracking: for the start of the tracking of the publication
  * Alter Publication: for changes in the publication tables and/or options
  * Drop Publication: for dropped publications
  * Stop Tracking: for stop the tracking of the publication
* user_action: the user who made the change in the publication.
* date_time: timestamp of the change.
* pub_initial_ddl: initial DDL of the publication before the change.
* pub_final_ddl: final DDL of the publication after the change.

The initial and final DD is the same when start tracking.

     dell=# select * from logicalrep_audit.track_publication('pub_categories');
      track_publication 
     -------------------

     (1 line)

     dell=# select * from logicalrep_audit.publication_history ;
     -[ RECORD 1 ]
     ---+-------------------------------------------------------------------------------------------------------------------------------------------------------
     pub_oid         | 18198
     pub_name        | pub_categories
     pub_database    | dell
     pub_action      | Start Tracking
     user_action     | postgres
     date_time       | 2022-04-12 11:53:02.638984
     pub_initial_ddl | CREATE PUBLICATION pub_categories FOR TABLE public.categories WITH (publish = 'insert, update, delete, truncate', publish_via_partition_root = false);
     pub_final_ddl   | CREATE PUBLICATION pub_categories FOR TABLE public.categories WITH (publish = 'insert, update, delete, truncate', publish_via_partition_root = false);
     
     dell=# alter publication pub_categories set (publish = 'insert');
     ALTER PUBLICATION
     dell=# alter publication pub_categories set (publish = 'insert, update');
     ALTER PUBLICATION
     dell=# select * from logicalrep_audit.publication_history order by date_time;
     -[ RECORD 1 ]---+-------------------------------------------------------------------------------------------------------------------------------------------------------
     pub_oid         | 18198
     pub_name        | pub_categories
     pub_database    | dell
     pub_action      | Start Tracking
     user_action     | postgres
     date_time       | 2022-04-12 11:53:02.638984
     pub_initial_ddl | CREATE PUBLICATION pub_categories FOR TABLE public.categories WITH (publish = 'insert, update, delete, truncate', publish_via_partition_root = false);
     pub_final_ddl   | CREATE PUBLICATION pub_categories FOR TABLE public.categories WITH (publish = 'insert, update, delete, truncate', publish_via_partition_root = false);
     -[ RECORD 2 ]---+-------------------------------------------------------------------------------------------------------------------------------------------------------
     pub_oid         | 18198
     pub_name        | pub_categories
     pub_database    | dell
     pub_action      | Alter Publication
     user_action     | postgres
     date_time       | 2022-04-12 12:34:31.25347
     pub_initial_ddl | CREATE PUBLICATION pub_categories FOR TABLE public.categories WITH (publish = 'insert, update, delete, truncate', publish_via_partition_root = false);
     pub_final_ddl   | CREATE PUBLICATION pub_categories FOR TABLE public.categories WITH (publish = 'insert', publish_via_partition_root = false);
     -[ RECORD 3 ]---+-------------------------------------------------------------------------------------------------------------------------------------------------------
     pub_oid         | 18198
     pub_name        | pub_categories
     pub_database    | dell
     pub_action      | Alter Publication
     user_action     | postgres
     date_time       | 2022-04-12 12:34:39.898422
     pub_initial_ddl | CREATE PUBLICATION pub_categories FOR TABLE public.categories WITH (publish = 'insert', publish_via_partition_root = false);
     pub_final_ddl   | CREATE PUBLICATION pub_categories FOR TABLE public.categories WITH (publish = 'insert, update', publish_via_partition_root = false);

#### Start the tracking of all publications in a database
Start tracking of all publications in the database logs on table publication_history all the changes made to the structure of all publications.

     dell=# select * from logicalrep_audit.track_all_publications();
      track_all_publications 
     -------------------

     (1 line)

     dell=# alter publication pub_products set (publish = 'insert, update');
     ALTER PUBLICATION
     dell=# alter publication pub_categories set (publish = 'insert, update, delete');
     ALTER PUBLICATION
     dell=# select * from logicalrep_audit.publication_history order by date_time;
     -[ RECORD 1 ]---+-------------------------------------------------------------------------------------------------------------------------------------------------------
     pub_oid         | 18198
     pub_name        | pub_categories
     pub_database    | dell
     pub_action      | Start Tracking
     user_action     | postgres
     date_time       | 2022-04-12 11:53:02.638984
     pub_initial_ddl | CREATE PUBLICATION pub_categories FOR TABLE public.categories WITH (publish = 'insert, update, delete, truncate', publish_via_partition_root = false);
     pub_final_ddl   | CREATE PUBLICATION pub_categories FOR TABLE public.categories WITH (publish = 'insert, update, delete, truncate', publish_via_partition_root = false);
     -[ RECORD 2 ]---+-------------------------------------------------------------------------------------------------------------------------------------------------------
     pub_oid         | 18198
     pub_name        | pub_categories
     pub_database    | dell
     pub_action      | Alter Publication
     user_action     | postgres
     date_time       | 2022-04-12 12:34:31.25347
     pub_initial_ddl | CREATE PUBLICATION pub_categories FOR TABLE public.categories WITH (publish = 'insert, update, delete, truncate', publish_via_partition_root = false);
     pub_final_ddl   | CREATE PUBLICATION pub_categories FOR TABLE public.categories WITH (publish = 'insert', publish_via_partition_root = false);
     -[ RECORD 3 ]---+-------------------------------------------------------------------------------------------------------------------------------------------------------
     pub_oid         | 18198
     pub_name        | pub_categories
     pub_database    | dell
     pub_action      | Alter Publication
     user_action     | postgres
     date_time       | 2022-04-12 12:34:39.898422
     pub_initial_ddl | CREATE PUBLICATION pub_categories FOR TABLE public.categories WITH (publish = 'insert', publish_via_partition_root = false);
     pub_final_ddl   | CREATE PUBLICATION pub_categories FOR TABLE public.categories WITH (publish = 'insert, update', publish_via_partition_root = false);
     -[ RECORD 4 ]---+-------------------------------------------------------------------------------------------------------------------------------------------------------
     pub_oid         | 18217
     pub_name        | pub_products
     pub_database    | dell
     pub_action      | Start Tracking
     user_action     | postgres
     date_time       | 2022-04-12 12:36:43.246432
     pub_initial_ddl | CREATE PUBLICATION pub_products WITH (publish = 'insert, update, delete, truncate', publish_via_partition_root = false);
     pub_final_ddl   | CREATE PUBLICATION pub_products WITH (publish = 'insert, update, delete, truncate', publish_via_partition_root = false);
     -[ RECORD 5 ]---+-------------------------------------------------------------------------------------------------------------------------------------------------------
     pub_oid         | 18217
     pub_name        | pub_products
     pub_database    | dell
     pub_action      | Alter Publication
     user_action     | postgres
     date_time       | 2022-04-12 12:37:27.097779
     pub_initial_ddl | CREATE PUBLICATION pub_products WITH (publish = 'insert, update, delete, truncate', publish_via_partition_root = false);
     pub_final_ddl   | CREATE PUBLICATION pub_products WITH (publish = 'insert, update', publish_via_partition_root = false);
     -[ RECORD 6 ]---+-------------------------------------------------------------------------------------------------------------------------------------------------------
     pub_oid         | 18198
     pub_name        | pub_categories
     pub_database    | dell
     pub_action      | Alter Publication
     user_action     | postgres
     date_time       | 2022-04-12 12:37:32.486881
     pub_initial_ddl | CREATE PUBLICATION pub_categories FOR TABLE public.categories WITH (publish = 'insert, update', publish_via_partition_root = false);
     pub_final_ddl   | CREATE PUBLICATION pub_categories FOR TABLE public.categories WITH (publish = 'insert, update, delete', publish_via_partition_root = false);

#### Reset the tracking of one publication


#### Reset the tracking of all publications in a database


#### Stop the tracking of one publication


#### Stop the tracking of all publications in a database


#### Start the tracking of one subscription


#### Start the tracking of all subscriptions in a database


#### Reset the tracking of one subscription


#### Reset the tracking of all subscriptions in a database


#### Stop the tracking of one subscription


#### Stop the tracking of all subscriptions in a database

