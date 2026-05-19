.PHONY: setup seed run full test lint sql clean

setup:
	uv run setup/generate.py --build-only
	$(MAKE) full

seed:
	uv run setup/generate.py
	$(MAKE) full

run:
	uv run dbt run

full:
	uv run dbt run --full-refresh

test:
	uv run dbt test

lint:
	uv run sqlfluff lint models/

sql:
	@uv run setup/sql.py "$(Q)"

clean:
	rm -rf target/ logs/ warehouse.duckdb warehouse.duckdb.wal
