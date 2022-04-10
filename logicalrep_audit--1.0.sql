--
-- Create schema for the extension
--
CREATE SCHEMA logicalrep_audit;

SET search_path TO logicalrep_audit, pg_catalog;



--
-- Logical replication DDL
--


-- Generate DDL publication
--select * from generate_ddl_publication('ca')
CREATE FUNCTION generate_ddl_publication(p_name name) RETURNS text AS
$$
DECLARE

	v_ddl_pub text;
	v_pg_pub pg_publication;
	v_tables_list text;
	v_pub_ops text;
	v_version text;

BEGIN

	SET search_path TO logicalrep_audit, pg_catalog;
	
	SELECT * INTO v_pg_pub FROM pg_publication WHERE pubname = p_name;
	
	IF found THEN

		v_ddl_pub := 'CREATE PUBLICATION ' || p_name;		
		
		-- Check if the publication is for all or a list aff tablas
		IF v_pg_pub.puballtables is true THEN

			v_ddl_pub := v_ddl_pub || ' FOR ALL TABLES';

		ELSE

			-- Add tables
			SELECT string_agg(relname, ', ' ORDER BY relname)
			FROM (
				  SELECT pn.nspname || '.' || pc.relname AS relname
				  FROM pg_publication_rel pr  JOIN pg_class pc ON (pr.prrelid = pc.oid)
											  JOIN pg_namespace pn ON (pc.relnamespace = pn.oid)
				  WHERE pc.relkind = 'r' AND pr.prpubid = v_pg_pub.oid
				  UNION
				  -- Add partitioned tables
				  SELECT pn.nspname || '.' || pc.relname
				  FROM pg_publication_rel pr  JOIN pg_inherits pi ON (pr.prrelid = pi.inhparent AND pr.prpubid = v_pg_pub.oid)
											  JOIN pg_class pc ON (pi.inhrelid = pc.oid)
											  JOIN pg_namespace pn ON (pc.relnamespace = pn.oid)
				  WHERE pi.inhparent IN (SELECT partrelid FROM pg_partitioned_table)) x
			INTO v_tables_list;
			
			IF v_tables_list is not null THEN

				v_ddl_pub := v_ddl_pub || ' FOR TABLE ' || v_tables_list;
	
			END IF;
			
		END IF;
		
		-- Actions for the publication
		SELECT 	concat_ws(', ', CASE WHEN pubinsert is true THEN 'insert' END,
								CASE WHEN pubupdate is true THEN 'update' END,
								CASE WHEN pubdelete is true THEN 'delete' END,
								CASE WHEN pubtruncate is true THEN 'truncate' END) INTO v_pub_ops
		FROM pg_publication WHERE oid = v_pg_pub.oid;
		
		v_ddl_pub := v_ddl_pub || ' WITH (publish = ''' || v_pub_ops || '''';
		
		SELECT substring(setting from 1 for 2) INTO v_version FROM pg_settings WHERE name LIKE 'server_version_num';
		
		IF v_version::int > 12 THEN
		
			IF v_pg_pub.pubviaroot is true THEN

				v_ddl_pub := v_ddl_pub || ' , publish_via_partition_root = true)';
				
			ELSE

				v_ddl_pub := v_ddl_pub || ' , publish_via_partition_root = false)';

			END IF;
			
		ELSE
		
			v_ddl_pub := v_ddl_pub || ')';
		
		END IF;
		
		v_ddl_pub := v_ddl_pub || ';';
	
	ELSE
	
		v_ddl_pub := 'The publication ' || p_name || ' does not exist.';
	
	END IF;
	
	RETURN v_ddl_pub;

END;
$$ LANGUAGE plpgsql;


--Stablish connection to the publisher to check that the slot is created
--select * from logicalrep_audit.connection_to_publisher('sub_ca')
CREATE FUNCTION connection_to_publisher(p_name name) RETURNS pg_foreign_server AS
$$
DECLARE

	v_pg_sub record;
	v_host text;
	v_port text;
	v_dbname text;
	v_user text;
	v_password text;
	v_string_conn text[];
	v_foreign_server pg_foreign_server;
	
BEGIN

	SET search_path TO logicalrep_audit, pg_catalog;
	
	SELECT * INTO v_pg_sub FROM pg_subscription WHERE subname = p_name;

	IF found THEN

		SELECT conn->>'host', conn->>'port', conn->>'dbname', conn->>'user', conn->>'password' INTO v_host, v_port, v_dbname, v_user, v_password
		FROM (SELECT json_object((string_to_array(replace(v_pg_sub.subconninfo, '=', ' '), ' '))) AS conn) x;
		
		EXECUTE 'CREATE EXTENSION IF NOT EXISTS postgres_fdw';
		
		v_string_conn := '{host=' || v_host || ',port=' || v_port || ',dbname=' || v_dbname || '}';
		
		EXECUTE 'CREATE SERVER IF NOT EXISTS publisher_server_' || v_host || '_' || v_dbname || ' FOREIGN DATA WRAPPER postgres_fdw
				 OPTIONS (host ''' || v_host || ''',
						  port ''' || v_port || ''',
						  dbname ''' || v_dbname || ''')';
			
		EXECUTE 'CREATE USER MAPPING IF NOT EXISTS FOR ' || v_user ||
				' SERVER publisher_server_' || v_host || '_' || v_dbname || 
				' OPTIONS (user ''' || v_user || ''',
						   password ''' || v_password || ''')';
			
		SELECT * INTO v_foreign_server FROM pg_foreign_server WHERE srvoptions = v_string_conn;
		
		RETURN v_foreign_server;
		
	ELSE
	
		RAISE EXCEPTION 'The subscription does not exist.';
	
	END IF;
	
END;
$$ LANGUAGE plpgsql;


-- Generate DDL subscription
--select * from generate_ddl_subscription('sub_cb');
CREATE FUNCTION generate_ddl_subscription(p_name name) RETURNS text AS
$$
DECLARE

	v_ddl_sub text;
	v_pg_sub record;
	v_stat_sub pg_stat_subscription;
	v_sub_rel record;
	v_sub_ops text;
	v_foreign_server pg_foreign_server;
	v_slots name;

BEGIN

	SET search_path TO logicalrep_audit, pg_catalog;
	
	SELECT oid, * INTO v_pg_sub FROM pg_subscription WHERE subname = p_name;
	
	IF found THEN

		--Get subscription stats
		SELECT * INTO v_stat_sub FROM pg_stat_subscription WHERE subname = p_name;
		
		--Get subscription rels
		SELECT srsubid, srsublsn, count(*) FILTER (WHERE srsubstate = 'r') AS r, count(*) FILTER (WHERE srsubstate = 'd') AS d, count(*) FILTER (WHERE srsubstate = 'i') AS i INTO v_sub_rel
		FROM pg_subscription_rel
		WHERE srsubid = v_pg_sub.oid
		GROUP BY srsubid, srsublsn;
		
		--Add connection and publication info
		v_ddl_sub := 'CREATE SUBSCRIPTION ' || v_pg_sub.subname || ' CONNECTION ''' || v_pg_sub.subconninfo || '''' || ' PUBLICATION ' || array_to_string(v_pg_sub.subpublications, ', ');
		
		--Check if connect is enable
		IF v_stat_sub.pid is null THEN

			v_sub_ops := 'connect = false';

		ELSE

			v_sub_ops := 'connect = true';

		END IF;
		
		--Check if is enable
		IF v_pg_sub.subenabled is false THEN

			v_sub_ops := v_sub_ops || ', enabled = false';

		ELSE

			v_sub_ops := v_sub_ops || ', enabled = true';
			
			v_sub_ops := replace(v_sub_ops, 'connect = false', 'connect = true');

		END IF;

		--Check if copy_data is enable
		IF (v_sub_rel.r <> 0 OR v_sub_rel.d <> 0) AND v_sub_rel.srsublsn is not null THEN
		
			v_sub_ops := v_sub_ops || ', copy_data = true';
		
		ELSEIF v_sub_rel.i <> 0 AND v_sub_rel.srsublsn is null THEN
		
			v_sub_ops := v_sub_ops || ', copy_data = true';
			
		ELSE
		
			v_sub_ops := v_sub_ops || ', copy_data = false';
		
		END IF;
		
		--Check if the slot name is in use
		--Create connection to the publisher to check if the tables have data
		EXECUTE 'SELECT * FROM connection_to_publisher(''' || p_name || ''')' INTO v_foreign_server;

		EXECUTE 'CREATE FOREIGN TABLE IF NOT EXISTS publisher_replication_slots_' || v_foreign_server.srvname || '(
					 slot_name name,
					 plugin name,
					 slot_type text,
					 datoid oid,
					 database name,
					 temporary boolean,
					 active boolean,
					 active_pid integer,
					 xmin1 xid options (column_name ''xmin''),
					 catalog_xmin xid,
					 restart_lsn pg_lsn,
					 confirmed_flush_lsn pg_lsn
					) SERVER ' || v_foreign_server.srvname || ' OPTIONS (schema_name ''pg_catalog'', table_name ''pg_replication_slots'')';

		EXECUTE 'SELECT slot_name FROM publisher_replication_slots_' || v_foreign_server.srvname || ' WHERE slot_name = ''' || v_pg_sub.subslotname || '''' INTO v_slots;

		IF v_slots is not null THEN

			v_sub_ops := v_sub_ops || ', create_slot = true';
			
			v_sub_ops := replace(v_sub_ops, 'connect = false', 'connect = true');

		ELSE

			v_sub_ops := v_sub_ops || ', create_slot = false';

		END IF;
		
		--Drop access to publisher
		EXECUTE 'DROP SERVER ' || v_foreign_server.srvname || ' CASCADE';
		
		--Get the slot name
		v_sub_ops := v_sub_ops || ', slot_name = ' || v_pg_sub.subslotname;
		
		--Get the synccommit value
		v_sub_ops := v_sub_ops || ', synchronous_commit = ''' || v_pg_sub.subsynccommit || '''';

		--Add subscription parameters info
		IF v_sub_ops is not null THEN

			v_ddl_sub := v_ddl_sub || ' WITH (' || v_sub_ops || ');';

		ELSE

			v_ddl_sub := v_ddl_sub || ';';

		END IF;

	ELSE

		v_ddl_sub := 'The subscription ' || p_name || ' does not exist.';

	END IF;
	
	RETURN v_ddl_sub;

END;
$$ LANGUAGE plpgsql;



--
-- Track publications
--


-- Track one publication
--select * from track_publication('aa')
CREATE FUNCTION track_publication(p_name name) RETURNS void AS
$$
DECLARE

	v_pg_pub pg_publication;
	v_action text;
	v_ddl_pub text;
	v_function text;

BEGIN

	SET search_path TO logicalrep_audit, pg_catalog;
	
	SELECT * INTO v_pg_pub FROM pg_publication WHERE pubname = p_name;
	
	IF found THEN
	
		-- Create table for store publications history if is the first tracking enabled
		CREATE TABLE IF NOT EXISTS publication_history(
			pub_oid oid not null,
			pub_name name not null,
			pub_database name not null,
			pub_action text not null,
			user_action text not null,
			date_time timestamp not null DEFAULT now(),
			pub_initial_ddl text not null,
			pub_final_ddl text,
			primary key (pub_oid, date_time));
	
		SELECT pub_action INTO v_action FROM publication_history WHERE pub_oid = v_pg_pub.oid ORDER BY date_time DESC LIMIT 1;
		
		IF v_action <> 'Start Tracking' OR v_action is null THEN

			SELECT * FROM generate_ddl_publication(p_name) INTO v_ddl_pub;

			INSERT INTO publication_history (pub_oid, pub_name, pub_database, pub_action, user_action, pub_initial_ddl, pub_final_ddl) VALUES
				(v_pg_pub.oid, v_pg_pub.pubname, current_database(), 'Start Tracking', current_user, v_ddl_pub, v_ddl_pub);

			-- Create trigger function to save the publications history
			v_function := '
				CREATE OR REPLACE FUNCTION save_publication_history() RETURNS event_trigger AS
				$body$
				DECLARE

					v_initial_ddl text;
					v_database name := current_database();
					v_obj record;
					v_final_ddl text;

				BEGIN
				
					SET search_path TO logicalrep_audit, pg_catalog;

					IF TG_TAG = ''ALTER PUBLICATION'' THEN

						FOR v_obj IN SELECT * FROM pg_event_trigger_ddl_commands()
						LOOP

							IF v_obj.objid IN (' || (SELECT string_agg(DISTINCT pub_oid::text, ', ') FROM publication_history) || ') THEN

								SELECT pub_final_ddl FROM publication_history WHERE pub_oid = v_obj.objid ORDER BY date_time DESC LIMIT 1 INTO v_initial_ddl;

								SELECT * FROM generate_ddl_publication(v_obj.object_identity) INTO v_final_ddl;

								INSERT INTO publication_history (pub_oid, pub_name, pub_database, pub_action, user_action, pub_initial_ddl, pub_final_ddl) VALUES
									(v_obj.objid, v_obj.object_identity, current_database(), initcap(v_obj.command_tag), current_user, v_initial_ddl, v_final_ddl);

							END IF;

						END LOOP;

					END IF;

					IF TG_TAG = ''DROP PUBLICATION'' THEN

						FOR v_obj IN SELECT * FROM pg_event_trigger_dropped_objects()
						LOOP

							IF v_obj.objid IN (' || (SELECT string_agg(DISTINCT pub_oid::text, ', ') FROM publication_history) || ') THEN

								SELECT pub_final_ddl FROM publication_history WHERE pub_oid = v_obj.objid ORDER BY date_time DESC LIMIT 1 INTO v_initial_ddl;

								v_final_ddl := tg_tag || '' '' || v_obj.object_identity || '';'';

								INSERT INTO publication_history (pub_oid, pub_name, pub_database, pub_action, user_action, pub_initial_ddl, pub_final_ddl) VALUES
									(v_obj.objid, v_obj.object_identity, current_database(), initcap(tg_tag), current_user, v_initial_ddl, v_final_ddl);

							END IF;

						END LOOP;

					END IF;

				END;
				$body$ LANGUAGE plpgsql';

			EXECUTE v_function;

			IF (SELECT evtname FROM pg_event_trigger WHERE evtname = 'tgr_alter_publication') is null THEN

				CREATE EVENT TRIGGER tgr_alter_publication
				ON ddl_command_end
				WHEN tag in ('ALTER PUBLICATION')
				EXECUTE PROCEDURE save_publication_history();

			END IF;

			IF (SELECT evtname FROM pg_event_trigger WHERE evtname = 'tgr_drop_publication') is null THEN
				CREATE EVENT TRIGGER tgr_drop_publication
				ON sql_drop
				WHEN tag in ('DROP PUBLICATION')
				EXECUTE PROCEDURE save_publication_history();

			END IF;
			
		ELSE
		
			RAISE NOTICE 'The publication % is already being tracked.', p_name;
		
		END IF;
		
	ELSE
	
		RAISE EXCEPTION 'The publication % does not exist in the database %.', p_name, current_database();
	
	END IF;
	
END;
$$ LANGUAGE plpgsql;


-- Track all publications
--select * from track_all_publications()
CREATE FUNCTION track_all_publications() RETURNS void AS
$$
DECLARE

	v_pg_pub pg_publication;
	v_ddl_pub text;
	v_function text;

BEGIN

	SET search_path TO logicalrep_audit, pg_catalog;
	
	SELECT * INTO v_pg_pub FROM pg_publication LIMIT 1;
		
	IF found THEN

		-- Create table for store publications history
		CREATE TABLE IF NOT EXISTS publication_history(
			pub_oid oid not null,
			pub_name name not null,
			pub_database name not null,
			pub_action text not null,
			user_action text not null,
			date_time timestamp not null DEFAULT now(),
			pub_initial_ddl text not null,
			pub_final_ddl text,
			primary key (pub_oid, date_time));
		
		
		FOR v_pg_pub IN SELECT * FROM pg_publication WHERE oid NOT IN (SELECT DISTINCT pub_oid FROM publication_history)
		LOOP			
				
			SELECT * FROM generate_ddl_publication(v_pg_pub.pubname) INTO v_ddl_pub;

			INSERT INTO publication_history (pub_oid, pub_name, pub_database, pub_action, user_action, pub_initial_ddl, pub_final_ddl) VALUES
				(v_pg_pub.oid, v_pg_pub.pubname, current_database(), 'Start Tracking', current_user, v_ddl_pub, v_ddl_pub);
		
		END LOOP;
		
		IF found THEN

			-- Create trigger function to save the publications history
			v_function := '
				CREATE OR REPLACE FUNCTION save_publication_history() RETURNS event_trigger AS
				$body$
				DECLARE

					v_initial_ddl text;
					v_database name := current_database();
					v_obj record;
					v_final_ddl text;

				BEGIN

					SET search_path TO logicalrep_audit, pg_catalog;

					IF TG_TAG = ''ALTER PUBLICATION'' THEN

						FOR v_obj IN SELECT * FROM pg_event_trigger_ddl_commands()
						LOOP

							IF v_obj.objid IN (' || (SELECT string_agg(DISTINCT pub_oid::text, ', ') FROM publication_history) || ') THEN

								SELECT pub_final_ddl FROM publication_history WHERE pub_oid = v_obj.objid ORDER BY date_time DESC LIMIT 1 INTO v_initial_ddl;

								SELECT * FROM generate_ddl_publication(v_obj.object_identity) INTO v_final_ddl;

								INSERT INTO publication_history (pub_oid, pub_name, pub_database, pub_action, user_action, pub_initial_ddl, pub_final_ddl) VALUES
									(v_obj.objid, v_obj.object_identity, current_database(), initcap(v_obj.command_tag), current_user, v_initial_ddl, v_final_ddl);

							END IF;

						END LOOP;

					END IF;

					IF TG_TAG = ''DROP PUBLICATION'' THEN

						FOR v_obj IN SELECT * FROM pg_event_trigger_dropped_objects()
						LOOP

							IF v_obj.objid IN (' || (SELECT string_agg(DISTINCT pub_oid::text, ', ') FROM publication_history) || ') THEN

								SELECT pub_final_ddl FROM publication_history WHERE pub_oid = v_obj.objid ORDER BY date_time DESC LIMIT 1 INTO v_initial_ddl;

								v_final_ddl := tg_tag || '' '' || v_obj.object_identity || '';'';

								INSERT INTO publication_history (pub_oid, pub_name, pub_database, pub_action, user_action, pub_initial_ddl, pub_final_ddl) VALUES
									(v_obj.objid, v_obj.object_identity, current_database(), initcap(tg_tag), current_user, v_initial_ddl, v_final_ddl);

							END IF;

						END LOOP;

					END IF;

				END;
				$body$ LANGUAGE plpgsql';

			EXECUTE v_function;

			-- Create trigger to track the publications history
			IF (SELECT evtname FROM pg_event_trigger WHERE evtname = 'tgr_alter_publication') is null THEN

				CREATE EVENT TRIGGER tgr_alter_publication
				ON ddl_command_end
				WHEN tag in ('ALTER PUBLICATION')
				EXECUTE PROCEDURE save_publication_history();

			END IF;

			IF (SELECT evtname FROM pg_event_trigger WHERE evtname = 'tgr_drop_publication') is null THEN

				CREATE EVENT TRIGGER tgr_drop_publication
				ON sql_drop
				WHEN tag in ('DROP PUBLICATION')
				EXECUTE PROCEDURE save_publication_history();

			END IF;
		
		ELSE
		
			RAISE NOTICE 'The existing publications are already being tracked.';
		
		END IF;

	ELSE
	
		RAISE EXCEPTION 'The database % has no publications.', current_database();
	
	END IF;
	
END;
$$ LANGUAGE plpgsql;



--
-- Reset publications tracking
--


-- Reset tracking for one publication
--select * from reset_publication_tracking('cc')
CREATE FUNCTION reset_publication_tracking(p_name name) RETURNS void AS
$$
DECLARE

	v_pub_history record;
	v_event_tgr_alter name;
	v_event_tgr_drop name;
	v_event_tgr_func name;
	v_pg_pub pg_publication;
	v_ddl_pub text;

BEGIN
	
	SET search_path TO logicalrep_audit, pg_catalog;
	
	SELECT * INTO v_pub_history FROM publication_history WHERE pub_name = p_name;
	
	IF v_pub_history is not null THEN
	
		SELECT * INTO v_event_tgr_alter FROM pg_event_trigger WHERE evtname = 'tgr_alter_publication';
		
		SELECT * INTO v_event_tgr_drop FROM pg_event_trigger WHERE evtname = 'tgr_drop_publication';
		
		SELECT * INTO v_event_tgr_func FROM pg_proc WHERE proname = 'save_publication_history';
		
		IF (v_event_tgr_alter is not null AND v_event_tgr_drop is not null AND v_event_tgr_func is not null) THEN
			
			SELECT * INTO v_pg_pub FROM pg_publication WHERE pubname = p_name;
			
			IF v_pg_pub is not null THEN
			
				DELETE FROM publication_history WHERE pub_oid = v_pg_pub.oid;
				
				SELECT * FROM generate_ddl_publication(v_pg_pub.pubname) INTO v_ddl_pub;

				INSERT INTO publication_history (pub_oid, pub_name, pub_database, pub_action, user_action, pub_initial_ddl, pub_final_ddl) VALUES
					(v_pg_pub.oid, v_pg_pub.pubname, current_database(), 'Start Tracking', current_user, v_ddl_pub, v_ddl_pub);
			
			ELSE
				
				RAISE EXCEPTION 'The publication % does not exist', p_name; --. Removed references to % in table publication_history.', p_name, p_name;
			
			END IF;
			
		ELSE
		
			RAISE EXCEPTION 'The tracking mecanism has errors.';
		
		END IF;
	
	ELSE
	
		RAISE EXCEPTION 'The table publication_history has no entries of the publication %.', p_name;
	
	END IF;
	
END;
$$ LANGUAGE plpgsql;


-- Reset tracking for all publications
--select * from reset_all_publications_tracking()
CREATE FUNCTION reset_all_publications_tracking() RETURNS void AS
$$
DECLARE

	v_pub_history record;
	v_event_tgr_alter name;
	v_event_tgr_drop name;
	v_event_tgr_func name;
	v_pg_pub pg_publication;
	v_ddl_pub text;
	v_pub record;

BEGIN
	
	SET search_path TO logicalrep_audit, pg_catalog;
	
	SELECT * INTO v_pub_history FROM publication_history;
	
	SELECT * INTO v_event_tgr_alter FROM pg_event_trigger WHERE evtname = 'tgr_alter_publication';
	
	SELECT * INTO v_event_tgr_drop FROM pg_event_trigger WHERE evtname = 'tgr_drop_publication';
	
	SELECT * INTO v_event_tgr_func FROM pg_proc WHERE proname = 'save_publication_history';
	
	IF (v_pub_history is not null AND v_event_tgr_alter is not null AND v_event_tgr_drop is not null AND v_event_tgr_func is not null) THEN
		
		FOR v_pg_pub IN SELECT * FROM pg_publication WHERE oid IN (SELECT DISTINCT pub_oid FROM publication_history)
		LOOP			
			
			DELETE FROM publication_history WHERE pub_oid = v_pg_pub.oid;
			
			SELECT * FROM generate_ddl_publication(v_pg_pub.pubname) INTO v_ddl_pub;

			INSERT INTO publication_history (pub_oid, pub_name, pub_database, pub_action, user_action, pub_initial_ddl, pub_final_ddl) VALUES
				(v_pg_pub.oid, v_pg_pub.pubname, current_database(), 'Start Tracking', current_user, v_ddl_pub, v_ddl_pub);
		
		END LOOP;
		
		FOR v_pub IN SELECT DISTINCT pub_oid, pub_name FROM publication_history WHERE pub_oid NOT IN (SELECT oid FROM pg_publication)
		LOOP
		
			DELETE FROM publication_history WHERE pub_oid = v_pub.pub_oid;
			
			RAISE NOTICE 'The publication % does not exist. Removed references to % in table publication_history.', v_pub.pub_name, v_pub.pub_name;
		
		END LOOP;
		
	ELSE
	
		RAISE EXCEPTION 'The tracking mecanism has errors.';
	
	END IF;
	
END;
$$ LANGUAGE plpgsql;



--
-- Stop publications tracking
--


-- Stop tracking for one publication
--select * from stop_publication_tracking('cc')
CREATE FUNCTION stop_publication_tracking(p_name name) RETURNS void AS
$$
DECLARE

	v_pg_pub pg_publication;
	v_action text;
	v_pub record;
	v_ddl_pub text;
	v_function text;

BEGIN
	
	SET search_path TO logicalrep_audit, pg_catalog;
	
	SELECT * INTO v_pg_pub FROM pg_publication WHERE pubname = p_name;
		
	IF found THEN

		SELECT * INTO v_pub FROM publication_history WHERE pub_oid = v_pg_pub.oid;
		
		IF found THEN
		
			SELECT pub_action INTO v_action FROM publication_history WHERE pub_oid = v_pg_pub.oid ORDER BY date_time DESC LIMIT 1;
			
			IF v_action <> 'Stop Tracking' OR v_action is null THEN
		
				SELECT * FROM generate_ddl_publication(v_pg_pub.pubname) INTO v_ddl_pub;

				INSERT INTO publication_history (pub_oid, pub_name, pub_database, pub_action, user_action, pub_initial_ddl, pub_final_ddl) VALUES
					(v_pg_pub.oid, v_pg_pub.pubname, current_database(), 'Stop Tracking', current_user, v_ddl_pub, v_ddl_pub);
			
				-- Recreate trigger function to save the publications history without p_name
				v_function := '
					CREATE OR REPLACE FUNCTION save_publication_history() RETURNS event_trigger AS
					$body$
					DECLARE
					
						v_initial_ddl text;
						v_database name := current_database();
						v_obj record;
						v_final_ddl text;

					BEGIN
					
						SET search_path TO logicalrep_audit, pg_catalog;
					
						IF TG_TAG = ''ALTER PUBLICATION'' THEN

							FOR v_obj IN SELECT * FROM pg_event_trigger_ddl_commands()
							LOOP
								
								IF v_obj.objid IN (' || (SELECT string_agg(DISTINCT pub_oid::text, ', ') FROM publication_history WHERE pub_oid <> v_pg_pub.oid) || ') THEN
								
									SELECT pub_final_ddl FROM publication_history WHERE pub_oid = v_obj.objid ORDER BY date_time DESC LIMIT 1 INTO v_initial_ddl;

									SELECT * FROM generate_ddl_publication(v_obj.object_identity) INTO v_final_ddl;

									INSERT INTO publication_history (pub_oid, pub_name, pub_database, pub_action, user_action, pub_initial_ddl, pub_final_ddl) VALUES
										(v_obj.objid, v_obj.object_identity, current_database(), initcap(v_obj.command_tag), current_user, v_initial_ddl, v_final_ddl);
								
								END IF;

							END LOOP;
						
						END IF;
						
						IF TG_TAG = ''DROP PUBLICATION'' THEN

							FOR v_obj IN SELECT * FROM pg_event_trigger_dropped_objects()
							LOOP

								IF v_obj.objid IN (' || (SELECT string_agg(DISTINCT pub_oid::text, ', ') FROM publication_history WHERE pub_oid <> v_pg_pub.oid) || ') THEN
								
									SELECT pub_final_ddl FROM publication_history WHERE pub_oid = v_obj.objid ORDER BY date_time DESC LIMIT 1 INTO v_initial_ddl;

									v_final_ddl := tg_tag || '' '' || v_obj.object_identity || '';'';

									INSERT INTO publication_history (pub_oid, pub_name, pub_database, pub_action, user_action, pub_initial_ddl, pub_final_ddl) VALUES
										(v_obj.objid, v_obj.object_identity, current_database(), initcap(tg_tag), current_user, v_initial_ddl, v_final_ddl);
								
								END IF;
		 
							END LOOP;
						
						END IF;
						
					END;
					$body$ LANGUAGE plpgsql';
			
				EXECUTE v_function;

				SELECT * INTO v_pub FROM publication_history WHERE pub_oid <> v_pg_pub.oid;

				IF not found THEN

					DROP EVENT TRIGGER tgr_alter_publication;

					DROP EVENT TRIGGER tgr_drop_publication;

					DROP FUNCTION save_publication_history();

				END IF;
			
			ELSE
			
				RAISE EXCEPTION 'The publication % is already being stopped.', p_name;
			
			END IF;
		
		ELSE
		
			RAISE EXCEPTION 'The publication % does not have tracking enabled.', p_name;
			
		END IF;
		
	ELSE
	
		RAISE EXCEPTION 'The publication % does not exist in the database %.', p_name, current_database();
	
	END IF;
	
END;
$$ LANGUAGE plpgsql;


-- Stop tracking of all publications
--select * from stop_all_publications_tracking()
CREATE FUNCTION stop_all_publications_tracking() RETURNS void AS
$$
DECLARE

	v_pg_pub pg_publication;
	v_action text;
	v_pub record;
	v_ddl_pub text;
	v_function text;
	v_event_tgr_alter name;
	v_event_tgr_drop name;
	v_event_tgr_func name;

BEGIN
	
	SET search_path TO logicalrep_audit, pg_catalog;
	
	FOR v_pg_pub IN SELECT * FROM pg_publication
	LOOP
	
		SELECT * INTO v_pub FROM publication_history WHERE pub_oid = v_pg_pub.oid;
		
		IF found THEN
		
			SELECT pub_action INTO v_action FROM publication_history WHERE pub_oid = v_pg_pub.oid ORDER BY date_time DESC LIMIT 1;
			
			IF v_action <> 'Stop Tracking' OR v_action is null THEN
		
				SELECT * FROM generate_ddl_publication(v_pg_pub.pubname) INTO v_ddl_pub;

				INSERT INTO publication_history (pub_oid, pub_name, pub_database, pub_action, user_action, pub_initial_ddl, pub_final_ddl) VALUES
					(v_pg_pub.oid, v_pg_pub.pubname, current_database(), 'Stop Tracking', current_user, v_ddl_pub, v_ddl_pub);
							
			ELSE
			
				RAISE NOTICE 'The publication % is already being stopped.', v_pub.pub_name;
			
			END IF;
		
		ELSE
		
			RAISE NOTICE 'The publication % does not have tracking enabled.', v_pub.pub_name;
			
		END IF;
		
	END LOOP;
	
	IF not found THEN

		RAISE NOTICE 'There are no publications in the database %.', current_database();
	
	END IF;
	
	SELECT * INTO v_event_tgr_alter FROM pg_event_trigger WHERE evtname = 'tgr_alter_publication';

	SELECT * INTO v_event_tgr_drop FROM pg_event_trigger WHERE evtname = 'tgr_drop_publication';

	SELECT * INTO v_event_tgr_func FROM pg_proc WHERE proname = 'save_publication_history';

	IF (v_event_tgr_alter is not null AND v_event_tgr_drop is not null AND v_event_tgr_func is not null) THEN

		DROP EVENT TRIGGER tgr_alter_publication;

		DROP EVENT TRIGGER tgr_drop_publication;

		DROP FUNCTION save_publication_history();

		RAISE NOTICE 'The tracking mecanism has been deleted.';

	ELSE

		RAISE EXCEPTION 'The tracking mecanism has errors.';
	
	END IF;
	
END;
$$ LANGUAGE plpgsql;



--
-- Track subscriptions
--


-- Track one subscription
--select * from track_subscription('sub_ca')
CREATE FUNCTION track_subscription(p_name name) RETURNS void AS
$$
DECLARE

	v_pg_sub pg_subscription;
	v_action text;
	v_ddl_sub text;
	v_function text;

BEGIN

	SET search_path TO logicalrep_audit, pg_catalog;
	
	SELECT * INTO v_pg_sub FROM pg_subscription WHERE subname = p_name;
	
	IF found THEN
	
		-- Create table for store subscription history if is the first tracking enabled
		CREATE TABLE IF NOT EXISTS subscription_history(
			sub_oid oid not null,
			sub_name name not null,
			sub_database name not null,
			sub_action text not null,
			user_action text not null,
			date_time timestamp not null DEFAULT now(),
			sub_initial_ddl text not null,
			sub_final_ddl text,
			primary key (sub_oid, date_time));
	
		SELECT sub_action INTO v_action FROM subscription_history WHERE sub_oid = v_pg_sub.oid ORDER BY date_time DESC LIMIT 1;
		
		IF v_action <> 'Start Tracking' OR v_action is null THEN

			SELECT * FROM generate_ddl_subscription(p_name) INTO v_ddl_sub;

			INSERT INTO subscription_history (sub_oid, sub_name, sub_database, sub_action, user_action, sub_initial_ddl, sub_final_ddl) VALUES
				(v_pg_sub.oid, v_pg_sub.subname, current_database(), 'Start Tracking', current_user, v_ddl_sub, v_ddl_sub);

			-- Create trigger function to save the subscriptions history
			v_function := '
				CREATE OR REPLACE FUNCTION save_subscription_history() RETURNS event_trigger AS
				$body$
				DECLARE

					v_initial_ddl text;
					v_database name := current_database();
					v_obj record;
					v_final_ddl text;

				BEGIN
				
					SET search_path TO logicalrep_audit, pg_catalog;

					IF TG_TAG = ''ALTER SUBSCRIPTION'' THEN

						FOR v_obj IN SELECT * FROM pg_event_trigger_ddl_commands()
						LOOP

							IF v_obj.objid IN (' || (SELECT string_agg(DISTINCT sub_oid::text, ', ') FROM subscription_history) || ') THEN

								SELECT sub_final_ddl FROM subscription_history WHERE sub_oid = v_obj.objid ORDER BY date_time DESC LIMIT 1 INTO v_initial_ddl;

								SELECT * FROM generate_ddl_subscription(v_obj.object_identity) INTO v_final_ddl;

								INSERT INTO subscription_history (sub_oid, sub_name, sub_database, sub_action, user_action, sub_initial_ddl, sub_final_ddl) VALUES
									(v_obj.objid, v_obj.object_identity, current_database(), initcap(v_obj.command_tag), current_user, v_initial_ddl, v_final_ddl);

							END IF;

						END LOOP;

					END IF;

					IF TG_TAG = ''DROP SUBSCRIPTION'' THEN

						FOR v_obj IN SELECT * FROM pg_event_trigger_dropped_objects()
						LOOP

							IF v_obj.objid IN (' || (SELECT string_agg(DISTINCT sub_oid::text, ', ') FROM subscription_history) || ') THEN

								SELECT sub_final_ddl FROM subscription_history WHERE sub_oid = v_obj.objid ORDER BY date_time DESC LIMIT 1 INTO v_initial_ddl;

								v_final_ddl := tg_tag || '' '' || v_obj.object_identity || '';'';

								INSERT INTO subscription_history (sub_oid, sub_name, sub_database, sub_action, user_action, sub_initial_ddl, sub_final_ddl) VALUES
									(v_obj.objid, v_obj.object_identity, current_database(), initcap(tg_tag), current_user, v_initial_ddl, v_final_ddl);

							END IF;

						END LOOP;

					END IF;

				END;
				$body$ LANGUAGE plpgsql';

			EXECUTE v_function;

			IF (SELECT evtname FROM pg_event_trigger WHERE evtname = 'tgr_alter_subscription') is null THEN

				CREATE EVENT TRIGGER tgr_alter_subscription
				ON ddl_command_end
				WHEN tag in ('ALTER SUBSCRIPTION')
				EXECUTE PROCEDURE save_subscription_history();

			END IF;

			IF (SELECT evtname FROM pg_event_trigger WHERE evtname = 'tgr_drop_subscription') is null THEN
				CREATE EVENT TRIGGER tgr_drop_subscription
				ON sql_drop
				WHEN tag in ('DROP SUBSCRIPTION')
				EXECUTE PROCEDURE save_subscription_history();

			END IF;
			
		ELSE
		
			RAISE EXCEPTION 'The subscription % is already being tracked.', p_name;
		
		END IF;
		
	ELSE
	
		RAISE EXCEPTION 'The subscription % does not exist in the database %.', p_name, current_database();
	
	END IF;
	
END;
$$ LANGUAGE plpgsql;


-- Track all subscriptions
--select * from track_all_subscriptions()
CREATE FUNCTION track_all_subscriptions() RETURNS void AS
$$
DECLARE

	v_pg_sub pg_subscription;
	v_ddl_sub text;
	v_function text;

BEGIN

	SET search_path TO logicalrep_audit, pg_catalog;
	
	SELECT * INTO v_pg_sub FROM pg_subscription LIMIT 1;
		
	IF found THEN

		-- Create table for store subscriptions history
		CREATE TABLE IF NOT EXISTS subscription_history(
			sub_oid oid not null,
			sub_name name not null,
			sub_database name not null,
			sub_action text not null,
			user_action text not null,
			date_time timestamp not null DEFAULT now(),
			sub_initial_ddl text not null,
			sub_final_ddl text,
			primary key (sub_oid, date_time));
		
		
		FOR v_pg_sub IN SELECT * FROM pg_subscription WHERE oid NOT IN (SELECT DISTINCT sub_oid FROM subscription_history)
		LOOP			
				
			SELECT * FROM generate_ddl_subscription(v_pg_sub.subname) INTO v_ddl_sub;

			INSERT INTO subscription_history (sub_oid, sub_name, sub_database, sub_action, user_action, sub_initial_ddl, sub_final_ddl) VALUES
				(v_pg_sub.oid, v_pg_sub.subname, current_database(), 'Start Tracking', current_user, v_ddl_sub, v_ddl_sub);
		
		END LOOP;
		
		IF found THEN

			-- Create trigger function to save the subscriptions history
			v_function := '
				CREATE OR REPLACE FUNCTION save_subscription_history() RETURNS event_trigger AS
				$body$
				DECLARE

					v_initial_ddl text;
					v_database name := current_database();
					v_obj record;
					v_final_ddl text;

				BEGIN
				
					SET search_path TO logicalrep_audit, pg_catalog;

					IF TG_TAG = ''ALTER SUBSCRIPTION'' THEN

						FOR v_obj IN SELECT * FROM pg_event_trigger_ddl_commands()
						LOOP

							IF v_obj.objid IN (' || (SELECT string_agg(DISTINCT sub_oid::text, ', ') FROM subscription_history) || ') THEN

								SELECT sub_final_ddl FROM subscription_history WHERE sub_oid = v_obj.objid ORDER BY date_time DESC LIMIT 1 INTO v_initial_ddl;

								SELECT * FROM generate_ddl_subscription(v_obj.object_identity) INTO v_final_ddl;

								INSERT INTO subscription_history (sub_oid, sub_name, sub_database, sub_action, user_action, sub_initial_ddl, sub_final_ddl) VALUES
									(v_obj.objid, v_obj.object_identity, current_database(), initcap(v_obj.command_tag), current_user, v_initial_ddl, v_final_ddl);

							END IF;

						END LOOP;

					END IF;

					IF TG_TAG = ''DROP SUBSCRIPTION'' THEN

						FOR v_obj IN SELECT * FROM pg_event_trigger_dropped_objects()
						LOOP

							IF v_obj.objid IN (' || (SELECT string_agg(DISTINCT sub_oid::text, ', ') FROM subscription_history) || ') THEN

								SELECT sub_final_ddl FROM subscription_history WHERE sub_oid = v_obj.objid ORDER BY date_time DESC LIMIT 1 INTO v_initial_ddl;

								v_final_ddl := tg_tag || '' '' || v_obj.object_identity || '';'';

								INSERT INTO subscription_history (sub_oid, sub_name, sub_database, sub_action, user_action, sub_initial_ddl, sub_final_ddl) VALUES
									(v_obj.objid, v_obj.object_identity, current_database(), initcap(tg_tag), current_user, v_initial_ddl, v_final_ddl);

							END IF;

						END LOOP;

					END IF;

				END;
				$body$ LANGUAGE plpgsql';

			EXECUTE v_function;
					
			-- Create trigger to track the subscriptions history
			IF (SELECT evtname FROM pg_event_trigger WHERE evtname = 'tgr_alter_subscription') is null THEN
			
				CREATE EVENT TRIGGER tgr_alter_subscription
				ON ddl_command_end
				WHEN tag in ('ALTER SUBSCRIPTION')
				EXECUTE PROCEDURE save_subscription_history();
			
			END IF;
			
			IF (SELECT evtname FROM pg_event_trigger WHERE evtname = 'tgr_drop_subscription') is null THEN

				CREATE EVENT TRIGGER tgr_drop_subscription
				ON sql_drop
				WHEN tag in ('DROP SUBSCRIPTION')
				EXECUTE PROCEDURE save_subscription_history();
			
			END IF;
		
		ELSE
		
			RAISE EXCEPTION 'The existing subscriptions are already being tracked.';
		
		END IF;
		
	ELSE
	
		RAISE EXCEPTION 'The database % has no subscriptions.', current_database();
	
	END IF;
	
END;
$$ LANGUAGE plpgsql;



--
-- Reset subscriptions tracking
--


-- Reset tracking for one subscription
--select * from reset_subscription_tracking('sub_cc')
CREATE FUNCTION reset_subscription_tracking(p_name name) RETURNS void AS
$$
DECLARE

	v_sub_history record;
	v_event_tgr_alter name;
	v_event_tgr_drop name;
	v_event_tgr_func name;
	v_pg_sub record;
	v_ddl_sub text;

BEGIN
	
	SET search_path TO logicalrep_audit, pg_catalog;
	
	SELECT * INTO v_sub_history FROM subscription_history WHERE sub_name = p_name;
	
	IF v_sub_history is not null THEN

		SELECT * INTO v_event_tgr_alter FROM pg_event_trigger WHERE evtname = 'tgr_alter_subscription';

		SELECT * INTO v_event_tgr_drop FROM pg_event_trigger WHERE evtname = 'tgr_drop_subscription';

		SELECT * INTO v_event_tgr_func FROM pg_proc WHERE proname = 'save_subscription_history';

		IF (v_event_tgr_alter is not null AND v_event_tgr_drop is not null AND v_event_tgr_func is not null) THEN

			SELECT oid, * INTO v_pg_sub FROM pg_subscription WHERE subname = p_name;

			IF v_pg_sub is not null THEN
			
				DELETE FROM subscription_history WHERE sub_oid = v_pg_sub.oid;

				SELECT * FROM generate_ddl_subscription(v_pg_sub.subname) INTO v_ddl_sub;

				INSERT INTO subscription_history (sub_oid, sub_name, sub_database, sub_action, user_action, sub_initial_ddl, sub_final_ddl) VALUES
					(v_pg_sub.oid, v_pg_sub.subname, current_database(), 'Start Tracking', current_user, v_ddl_sub, v_ddl_sub);

			ELSE

				RAISE EXCEPTION 'The subscription % does not exist', p_name; --. Removed references to % in table subscription_history.', p_name, p_name;

			END IF;

		ELSE

			RAISE EXCEPTION 'The tracking mecanism has errors.';

		END IF;
	
	ELSE
	
		RAISE EXCEPTION 'The table subscription_history has no entries of the subscription %.', p_name;
		
	END IF;
	
END;
$$ LANGUAGE plpgsql;


-- Reset tracking for all subscriptions
--select * from reset_all_subscriptions_tracking()
CREATE FUNCTION reset_all_subscriptions_tracking() RETURNS void AS
$$
DECLARE

	v_sub_history record;
	v_event_tgr_alter name;
	v_event_tgr_drop name;
	v_event_tgr_func name;
	v_pg_sub record;
	v_ddl_sub text;
	v_sub record;

BEGIN
	
	SET search_path TO logicalrep_audit, pg_catalog;
	
	SELECT * INTO v_sub_history FROM subscription_history;
		
	SELECT * INTO v_event_tgr_alter FROM pg_event_trigger WHERE evtname = 'tgr_alter_subscription';
	
	SELECT * INTO v_event_tgr_drop FROM pg_event_trigger WHERE evtname = 'tgr_drop_subscription';
	
	SELECT * INTO v_event_tgr_func FROM pg_proc WHERE proname = 'save_subscription_history';
	
	IF (v_sub_history is not null AND v_event_tgr_alter is not null AND v_event_tgr_drop is not null AND v_event_tgr_func is not null) THEN
		
		FOR v_pg_sub IN SELECT oid, * FROM pg_subscription WHERE oid IN (SELECT DISTINCT sub_oid FROM subscription_history)
		LOOP			
			
			DELETE FROM subscription_history WHERE sub_oid = v_pg_sub.oid;
			
			SELECT * FROM generate_ddl_subscription(v_pg_sub.subname) INTO v_ddl_sub;

			INSERT INTO subscription_history (sub_oid, sub_name, sub_database, sub_action, user_action, sub_initial_ddl, sub_final_ddl) VALUES
				(v_pg_sub.oid, v_pg_sub.subname, current_database(), 'Start Tracking', current_user, v_ddl_sub, v_ddl_sub);
		
		END LOOP;
		
		FOR v_sub IN SELECT DISTINCT sub_name, sub_oid FROM subscription_history WHERE sub_oid NOT IN (SELECT oid FROM pg_subscription)
		LOOP
		
			DELETE FROM subscription_history WHERE sub_oid = v_sub.sub_oid;
			
			RAISE NOTICE 'The subscription % does not exist. Removed references from % in table subscription_history.', v_sub.sub_name, v_sub.sub_name;
		
		END LOOP;
		
	ELSE
	
		RAISE EXCEPTION 'The tracking mecanism has errors.';
	
	END IF;
	
END;
$$ LANGUAGE plpgsql;



--
-- Stop subscriptions tracking
--


-- Stop tracking for one subscription
--select * from stop_subscription_tracking('cc')
CREATE FUNCTION stop_subscription_tracking(p_name name) RETURNS void AS
$$
DECLARE

	v_pg_sub pg_subscription;
	v_sub record;
	v_action text;
	v_ddl_sub text;
	v_function text;

BEGIN
	
	SET search_path TO logicalrep_audit, pg_catalog;
	
	SELECT * INTO v_pg_sub FROM pg_subscription WHERE subname = p_name;
		
	IF found THEN
	
		SELECT * INTO v_sub FROM subscription_history WHERE sub_name = p_name;

		IF found THEN
		
			SELECT sub_action INTO v_action FROM subscription_history WHERE sub_oid = v_sub.sub_oid ORDER BY date_time DESC LIMIT 1;
		
			IF v_action <> 'Stop Tracking' THEN -- OR v_action is null THEN

				SELECT * FROM generate_ddl_subscription(v_pg_sub.subname) INTO v_ddl_sub;

				INSERT INTO subscription_history (sub_oid, sub_name, sub_database, sub_action, user_action, sub_initial_ddl, sub_final_ddl) VALUES
					(v_pg_sub.oid, v_pg_sub.subname, current_database(), 'Stop Tracking', current_user, v_ddl_sub, v_ddl_sub);

				-- Recreate trigger function to save the subscriptions history without p_name
				v_function := '
					CREATE OR REPLACE FUNCTION save_subscription_history() RETURNS event_trigger AS
					$body$
					DECLARE

						v_initial_ddl text;
						v_database name := current_database();
						v_obj record;
						v_final_ddl text;

					BEGIN

						SET search_path TO logicalrep_audit, pg_catalog;

						IF TG_TAG = ''ALTER SUBSCRIPTION'' THEN

							FOR v_obj IN SELECT * FROM pg_event_trigger_ddl_commands()
							LOOP

								IF v_obj.objid IN (' || (SELECT string_agg(DISTINCT sub_oid::text, ', ') FROM subscription_history WHERE sub_oid <> v_pg_sub.oid) || ') THEN

									SELECT sub_final_ddl FROM subscription_history WHERE sub_oid = v_obj.objid ORDER BY date_time DESC LIMIT 1 INTO v_initial_ddl;

									SELECT * FROM generate_ddl_subscription(v_obj.object_identity) INTO v_final_ddl;

									INSERT INTO subscription_history (sub_oid, sub_name, sub_database, sub_action, user_action, sub_initial_ddl, sub_final_ddl) VALUES
										(v_obj.objid, v_obj.object_identity, current_database(), initcap(v_obj.command_tag), current_user, v_initial_ddl, v_final_ddl);

								END IF;

							END LOOP;

						END IF;

						IF TG_TAG = ''DROP SUBSCRIPTION'' THEN

							FOR v_obj IN SELECT * FROM pg_event_trigger_dropped_objects()
							LOOP

								IF v_obj.objid IN (' || (SELECT string_agg(DISTINCT sub_oid::text, ', ') FROM subscription_history WHERE sub_oid <> v_pg_sub.oid) || ') THEN

									SELECT sub_final_ddl FROM subscription_history WHERE sub_oid = v_obj.objid ORDER BY date_time DESC LIMIT 1 INTO v_initial_ddl;

									v_final_ddl := tg_tag || '' '' || v_obj.object_identity || '';'';

									INSERT INTO subscription_history (sub_oid, sub_name, sub_database, sub_action, user_action, sub_initial_ddl, sub_final_ddl) VALUES
										(v_obj.objid, v_obj.object_identity, current_database(), initcap(tg_tag), current_user, v_initial_ddl, v_final_ddl);

								END IF;

							END LOOP;

						END IF;

					END;
					$body$ LANGUAGE plpgsql';

				EXECUTE v_function;

				SELECT * INTO v_sub FROM subscription_history WHERE sub_oid <> v_pg_sub.oid;

				IF not found THEN

					DROP EVENT TRIGGER tgr_alter_subscription;

					DROP EVENT TRIGGER tgr_drop_subscription;

					DROP FUNCTION save_subscription_history();

				END IF;
		
			ELSE

				RAISE EXCEPTION 'The subscription % is already being stopped.', p_name;

			END IF;
		
		ELSE
		
			RAISE EXCEPTION 'The subscription % does not have tracking enabled.', p_name;
		
		END IF;
		
	ELSE
	
		RAISE EXCEPTION 'The subscription % does not exist in the database %.', p_name, current_database();
	
	END IF;
	
END;
$$ LANGUAGE plpgsql;


-- Stop tracking of all subscriptions
--select * from stop_all_subscriptions_tracking()
CREATE FUNCTION stop_all_subscriptions_tracking() RETURNS void AS
$$
DECLARE

	v_pg_sub pg_subscription;
	v_action text;
	v_sub record;
	v_ddl_sub text;
	v_function text;
	v_event_tgr_alter name;
	v_event_tgr_drop name;
	v_event_tgr_func name;

BEGIN
	
	SET search_path TO logicalrep_audit, pg_catalog;
	
	FOR v_pg_sub IN SELECT * FROM pg_subscription
	LOOP
	
		SELECT * INTO v_sub FROM subscription_history WHERE sub_oid = v_pg_sub.oid;
		
		IF found THEN
		
			SELECT sub_action INTO v_action FROM subscription_history WHERE sub_oid = v_pg_sub.oid ORDER BY date_time DESC LIMIT 1;
			
			IF v_action <> 'Stop Tracking' OR v_action is null THEN
		
				SELECT * FROM generate_ddl_subscription(v_pg_sub.subname) INTO v_ddl_sub;

				INSERT INTO subscription_history (sub_oid, sub_name, sub_database, sub_action, user_action, sub_initial_ddl, sub_final_ddl) VALUES
					(v_pg_sub.oid, v_pg_sub.subname, current_database(), 'Stop Tracking', current_user, v_ddl_sub, v_ddl_sub);
							
			ELSE
			
				RAISE NOTICE 'The subscription % is already being stopped.', v_sub.sub_name;
			
			END IF;
		
		ELSE
		
			RAISE NOTICE 'The subscription % does not have tracking enabled.', v_sub.sub_name;
			
		END IF;
		
	END LOOP;
	
	IF not found THEN

		RAISE NOTICE 'There are no subscriptions in the database %.', current_database();
	
	END IF;
	
	SELECT * INTO v_event_tgr_alter FROM pg_event_trigger WHERE evtname = 'tgr_alter_subscription';

	SELECT * INTO v_event_tgr_drop FROM pg_event_trigger WHERE evtname = 'tgr_drop_subscription';

	SELECT * INTO v_event_tgr_func FROM pg_proc WHERE proname = 'save_subscription_history';

	IF (v_event_tgr_alter is not null AND v_event_tgr_drop is not null AND v_event_tgr_func is not null) THEN

		DROP EVENT TRIGGER tgr_alter_subscription;

		DROP EVENT TRIGGER tgr_drop_subscription;

		DROP FUNCTION save_subscription_history();

		RAISE NOTICE 'The tracking mecanism has been deleted.';

	ELSE

		RAISE EXCEPTION 'The tracking mecanism has errors.';
	
	END IF;
	
END;
$$ LANGUAGE plpgsql;
