package store

import (
	"database/sql"
	"testing"

	_ "github.com/duckdb/duckdb-go/v2"
)

// Sanity check the upsert statement against the bundled DuckDB version.
func TestUpsertCurrentTimestamp(t *testing.T) {
	db, err := sql.Open("duckdb", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	if _, err := db.Exec(`CREATE TABLE votes (
        ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        survey_id VARCHAR NOT NULL,
        answer VARCHAR NOT NULL,
        voter VARCHAR NOT NULL,
        PRIMARY KEY (survey_id, voter)
    )`); err != nil {
		t.Fatalf("create: %v", err)
	}

	// First insert
	if _, err := db.Exec(`
        INSERT INTO votes (survey_id, answer, voter) VALUES ('s1','good','v1')
        ON CONFLICT (survey_id, voter) DO UPDATE
        SET answer = excluded.answer, ts = now()
    `); err != nil {
		t.Fatalf("insert 1: %v", err)
	}

	// Second insert triggers update branch
	if _, err := db.Exec(`
        INSERT INTO votes (survey_id, answer, voter) VALUES ('s1','ok','v1')
        ON CONFLICT (survey_id, voter) DO UPDATE
        SET answer = excluded.answer, ts = now()
    `); err != nil {
		t.Fatalf("insert 2: %v", err)
	}
}
