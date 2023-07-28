<div align="center">
  <a href="https://encore.dev" alt="encore"><img width="189px" src="https://encore.dev/assets/img/logo.svg"></a>
  <h3><a href="https://encore.dev">Encore – The Backend Development Engine</a></h3>
</div>

# Postgres image for Encore

This is the Postgres docker image used by Encore for local development. It's based on Postgres 15 and includes
additional commonly used extensions.

## Extensions

The below additional extensions are installed and available via `CREATE EXTENSION`:

* `postgis`
* `pgvector`
