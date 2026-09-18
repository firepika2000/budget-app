-- Recovery is allowed only into a new/schema-only destination. Lock before checking so the
-- same transaction can safely apply the dump without an application writer racing the guard.
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';
DO $recovery$
DECLARE
    relation record;
    populated boolean;
BEGIN
    FOR relation IN
        SELECT schemaname, tablename FROM pg_tables
        WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
          AND schemaname NOT LIKE 'pg\_%' ESCAPE '\'
          AND NOT (schemaname = 'public' AND tablename = 'alembic_version')
        ORDER BY schemaname, tablename
    LOOP
        EXECUTE format('LOCK TABLE %I.%I IN ACCESS EXCLUSIVE MODE', relation.schemaname, relation.tablename);
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.%I LIMIT 1)', relation.schemaname, relation.tablename) INTO populated;
        IF populated THEN
            RAISE EXCEPTION 'Restore requires an empty recovery destination; existing data was not changed';
        END IF;
    END LOOP;
END;
$recovery$;
