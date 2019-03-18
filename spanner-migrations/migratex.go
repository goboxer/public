package main

//revive:disable:deep-exit

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io/ioutil"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode"

	"cloud.google.com/go/spanner"
	database "cloud.google.com/go/spanner/admin/database/apiv1"
	"google.golang.org/api/iterator"
	adminpb "google.golang.org/genproto/googleapis/spanner/admin/database/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
)

type Severity int

const (
	red    = 31
	green  = 32
	yellow = 33
	cyan   = 36

	colorDebug = green
	colorInfo  = cyan
	colorWarn  = yellow
	colorError = red
	colorFatal = red

	SeverityDebug     = iota
	SeverityInfo      = iota
	SeverityNotice    = iota
	SeverityWarning   = iota
	SeverityError     = iota
	SeverityEmergency = iota
)

var (
	l *logger

	envId             string
	gcpProjectId      string
	spannerInstanceId string
	spannerDatabaseId string
	timeout           int
)

func init() {
	l = newDefaultLogger(true)

	flag.StringVar(&envId, "env_id", "", "The environment ID of the spanner instance")
	flag.StringVar(&gcpProjectId, "gcp_project_id", "", "The GCP project ID of the spanner instance")
	flag.StringVar(&spannerInstanceId, "spanner_instance_id", "", "The ID of the spanner instance")
	flag.StringVar(&spannerDatabaseId, "spanner_database_id", "", "The ID of the spanner database")
	flag.IntVar(&timeout, "timeout", 60, "The timeout in minutes")

	flag.Parse()
}

func main() {
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeout)*time.Minute)
	defer cancel()

	logDebug(fmt.Sprintf("Starting in env: %v", map[string][]string{"os.Environ()": os.Environ()}))

	logDebug(fmt.Sprintf("Checking args"))
	if err := checkArgs(); err != nil {
		logFatal(fmt.Sprintf("Failed checking required command line arguments: %v", err))
	}
	logDebug(fmt.Sprintf("Checked args"))

	databseConnection := fmt.Sprintf("projects/%s/instances/%s/databases/%s", gcpProjectId, spannerInstanceId, spannerDatabaseId)

	logDebug(fmt.Sprintf("Using envId=%q, gcpProjectId=%q, spannerInstanceId=%q, spannerDatabaseId=%q, databseConnection=%q, timeout=%d", envId, gcpProjectId, spannerInstanceId, spannerDatabaseId, databseConnection, timeout))

	workingDir, err := os.Getwd()
	if err != nil {
		logFatal(fmt.Sprintf("Failed determining working directory: %v", err))
	}
	logDebug(fmt.Sprintf("Determined working directory %q", workingDir))

	logInfo("Beginning migration")

	ddl, dml := determineMigrations(workingDir)

	if len(ddl) == 0 && len(dml) == 0 {
		logInfo(fmt.Sprintf("No migrations found"))
		return
	}

	if len(dml) == 0 {
		logInfo(fmt.Sprintf("No DML migrations found, will apply all DDL migrations..."))
		applyAllDdlMigrations(workingDir)
		return
	}

	logInfo("DDL and DML migrations found, will determine if any are outstanding...")

	spannerClient, spannerAdminClient := newSpannerClient(ctx, databseConnection)
	defer spannerClient.Close()
	defer spannerAdminClient.Close()
	cleanUpAndExitOnInterrupt([]Closable{spannerClient})

	logInfo(fmt.Sprintf("Determining last DDL migration..."))
	createMigrationTableIfNecessary(ctx, spannerAdminClient, databseConnection, "SchemaMigrations")
	dirty, lastDdlMigration := determineLastMigration(ctx, spannerClient, "SchemaMigrations")
	if dirty {
		logFatal(fmt.Sprintf("SchemaMigrations table is dirty, this must be manually fixed before more migrations can be applied"))
	}

	logInfo(fmt.Sprintf("Determining last DML migration..."))
	createMigrationTableIfNecessary(ctx, spannerAdminClient, databseConnection, "DataMigrations")
	dirty, lastDmlMigration := determineLastMigration(ctx, spannerClient, "DataMigrations")
	if dirty {
		logFatal(fmt.Sprintf("DataMigrations table is dirty, this must be manually fixed before more migrations can be applied"))
	}

	outstandingDdlMigrations, outstandingDmlMigrations := outstandingMigrations(ddl, dml, lastDdlMigration, lastDmlMigration)

	if len(outstandingDdlMigrations)+len(outstandingDmlMigrations) == 0 {
		logInfo(fmt.Sprintf("No outstanding migrations found"))
		return
	}

	if len(outstandingDmlMigrations) == 0 {
		logInfo(fmt.Sprintf("No outstanding DML migrations found, will apply all DDL migrations..."))
		applyAllDdlMigrations(workingDir)
		return
	}

	logInfo("Outstanding DDL and DML migrations found, will apply all interleaved...")

	applyAllMigrations(ctx, spannerClient, workingDir, lastDmlMigration, outstandingDdlMigrations, outstandingDmlMigrations)

	logInfo("Finished migration")
}

func checkArgs() error {
	if envId == "" {
		return errors.New("Missing command line argument `env_id`")

	} else if gcpProjectId == "" {
		return errors.New("Missing command line argument `gcp_project_id`")

	} else if spannerInstanceId == "" {
		return errors.New("Missing command line argument `spanner_instance_id`")

	} else if spannerDatabaseId == "" {
		return errors.New("Missing command line argument `spanner_database_id`")
	}
	return nil
}

func determineMigrations(dir string) (ddl []string, dml []string) {
	logInfo(fmt.Sprintf("Determining migrations..."))

	files, err := ioutil.ReadDir(dir)
	if err != nil {
		logFatal(fmt.Sprintf("Failed reading files in directory %q: %v", dir, err))
	}

	if len(files) == 0 {
		logDebug(fmt.Sprintf("Found no files in directory %q", dir))
	}

	for _, v := range files {
		logDebug(fmt.Sprintf("Found file %q", v.Name()))

		if strings.HasSuffix(v.Name(), ".ddl.up.sql") {
			ddl = append(ddl, v.Name())

		} else if strings.HasSuffix(v.Name(), ".all.dml.sql") {
			dml = append(dml, v.Name())

		} else if strings.HasSuffix(v.Name(), fmt.Sprintf(".%s.dml.sql", envId)) {
			dml = append(dml, v.Name())

		} else if strings.HasSuffix(v.Name(), ".dml.sql") && strings.Contains(v.Name(), fmt.Sprintf(".%s.", envId)) {
			dml = append(dml, v.Name())
		}
	}

	logInfo(fmt.Sprintf("Found '%d' DDL migrations: %v", len(ddl), ddl))
	logInfo(fmt.Sprintf("Found '%d' DML migrations: %v", len(dml), dml))

	return
}

func applyAllDdlMigrations(dir string) {
	logInfo(fmt.Sprintf("Applying all DDL migrations..."))

	cmd := exec.Command("migrate", "-path", dir, "-database", fmt.Sprintf("spanner://projects/%s/instances/%s/databases/%s", gcpProjectId, spannerInstanceId, spannerDatabaseId), "up")
	var outb, errb bytes.Buffer
	cmd.Stdout = &outb
	cmd.Stderr = &errb

	logInfo(fmt.Sprintf("Applying all DDL migrations: %v", cmd.Args))
	if err := cmd.Run(); err != nil {
		logFatal(fmt.Sprintf("Failed applying all DDL migrations Stdout=%q, Stderr=%q: %v", outb.String(), errb.String(), err))
	}
	logInfo(fmt.Sprintf("Finished applying all DDL migrations Stdout=%q, Stderr=%q", outb.String(), errb.String()))
}

func applyNextDdlMigration(dir string) {
	logInfo(fmt.Sprintf("Applying next DDL migration..."))

	cmd := exec.Command("migrate", "-path", dir, "-database", fmt.Sprintf("spanner://projects/%s/instances/%s/databases/%s", gcpProjectId, spannerInstanceId, spannerDatabaseId), "up", "1")
	var outb, errb bytes.Buffer
	cmd.Stdout = &outb
	cmd.Stderr = &errb

	logInfo(fmt.Sprintf("Applying next DDL migration: %v", cmd.Args))
	if err := cmd.Run(); err != nil {
		logFatal(fmt.Sprintf("Failed applying next DDL migration Stdout=%q, Stderr=%q: %v", outb.String(), errb.String(), err))
	}
	logInfo(fmt.Sprintf("Finished applying next DDL migration Stdout=%q, Stderr=%q", outb.String(), errb.String()))
}

func determineLastMigration(ctx context.Context, spannerClient *spanner.Client, migrationTableName string) (bool, int64) {
	stmt := spanner.Statement{SQL: fmt.Sprintf("SELECT Dirty, Version FROM %s ORDER BY Version DESC LIMIT 1", migrationTableName)}
	iter := spannerClient.Single().Query(ctx, stmt)
	defer iter.Stop()
	for {
		row, err := iter.Next()
		if err == iterator.Done {
			logInfo(fmt.Sprintf("No existing migrations found in table %q: %v", migrationTableName, err))
			return false, 0
		}
		if err != nil {
			logFatal(fmt.Sprintf("Failed determining last migration in table %q: %v", migrationTableName, err))
		}
		var dirty bool
		var version int64
		if err := row.Columns(&dirty, &version); err != nil {
			logFatal(fmt.Sprintf("Failed determining last migration in table %q, could not unpack columns: %v", migrationTableName, err))
		}
		logInfo(fmt.Sprintf("Last migration in table %q: '%d'", migrationTableName, version))
		return dirty, version
	}
}

func outstandingMigrations(availableDdlMigrations, availableDmlMigrations []string, lastDdlMigration, lastDmlMigration int64) (ddl []string, dml []string) {
	logInfo(fmt.Sprintf("Determining outstanding DDL and DML migrations..."))

	for _, v := range availableDdlMigrations {
		if version, err := strconv.ParseInt(strings.Split(v, "_")[0], 10, 64); err == nil {
			if version > lastDdlMigration {
				if version < lastDmlMigration {
					logFatal(fmt.Sprintf("Found inconsistent migration state. Outstanding DDL migration %q should have already been applied since it comes before the current DML migration version '%d'", v, lastDmlMigration))
				}
				ddl = append(ddl, v)
			}
		} else {
			logFatal(fmt.Sprintf("Failed determining DDL migration version from file name %q: %v", v, err))
		}
	}

	for _, v := range availableDmlMigrations {
		if version, err := strconv.ParseInt(strings.Split(v, "_")[0], 10, 64); err == nil {
			if version > lastDmlMigration {
				if version < lastDdlMigration {
					logFatal(fmt.Sprintf("Found inconsistent migration state. Outstanding DML migration %q should have already been applied since it comes before the current DDL migration version '%d'", v, lastDdlMigration))
				}
				dml = append(dml, v)
			}
		} else {
			logFatal(fmt.Sprintf("Failed determining DML migration version from file name %q: %v", v, err))
		}
	}

	logInfo(fmt.Sprintf("Found '%d' outstanding DDL migrations: %v", len(ddl), ddl))
	logInfo(fmt.Sprintf("Found '%d' outstanding DML migrations: %v", len(dml), dml))

	return
}

func createMigrationTableIfNecessary(ctx context.Context, spannerAdminClient *database.DatabaseAdminClient, databseConnection, migrationTableName string) {
	logInfo(fmt.Sprintf("If necessary the %q table will be created", migrationTableName))

	op, err := spannerAdminClient.UpdateDatabaseDdl(ctx, &adminpb.UpdateDatabaseDdlRequest{
		Database: databseConnection,
		Statements: []string{
			fmt.Sprintf("CREATE TABLE %s (Version INT64 NOT NULL, Dirty BOOL NOT NULL) PRIMARY KEY (Version)", migrationTableName),
		},
	})
	if err != nil {
		logFatal(fmt.Sprintf("Failed creating the %q table: %v", migrationTableName, err))
	}
	if err := op.Wait(ctx); err != nil {
		logDebug(fmt.Sprintf("DDL request returned code=%q, desc=%q", grpc.Code(err), grpc.ErrorDesc(err)))
		if grpc.Code(err) == codes.FailedPrecondition && strings.Contains(grpc.ErrorDesc(err), "Duplicate name in schema") && strings.Contains(grpc.ErrorDesc(err), migrationTableName) {
			logDebug(fmt.Sprintf("%q table already exists", migrationTableName))
			return
		}
		logFatal(fmt.Sprintf("Failed creating the %q table after waiting: %v", migrationTableName, err))
	}
	logInfo(fmt.Sprintf("If necessary the %q table has been created", migrationTableName))
}

func applyAllMigrations(ctx context.Context, spannerClient *spanner.Client, dir string, currentDmlMigrationVersion int64, outstandingDdlMigrations, outstandingDmlMigrations []string) {
	logInfo(fmt.Sprintf("Applying all migrations..."))

	outstandingMigrations := append(outstandingDdlMigrations, outstandingDmlMigrations...)
	sort.Strings(outstandingMigrations)

	logInfo(fmt.Sprintf("Applying '%d' outstanding migrations: %v", len(outstandingMigrations), outstandingMigrations))

	for _, v := range outstandingMigrations {
		logDebug(fmt.Sprintf("Applying outstanding migration %q where current DML migration version is '%d'", v, currentDmlMigrationVersion))

		if strings.HasSuffix(v, ".ddl.up.sql") {
			applyNextDdlMigration(dir)

		} else if strings.HasSuffix(v, ".all.dml.sql") {
			currentDmlMigrationVersion = applyDmlMigration(ctx, spannerClient, dir, currentDmlMigrationVersion, v)

		} else if strings.HasSuffix(v, fmt.Sprintf(".%s.dml.sql", envId)) {
			currentDmlMigrationVersion = applyDmlMigration(ctx, spannerClient, dir, currentDmlMigrationVersion, v)

		} else if strings.HasSuffix(v, ".dml.sql") && strings.Contains(v, fmt.Sprintf(".%s.", envId)) {
			currentDmlMigrationVersion = applyDmlMigration(ctx, spannerClient, dir, currentDmlMigrationVersion, v)
		}
	}
}

func applyDmlMigration(ctx context.Context, spannerClient *spanner.Client, dir string, currentDmlMigrationVersion int64, migration string) int64 {
	logInfo(fmt.Sprintf("Appyling next DML migration %q from directory %q", migration, dir))

	var nextDmlMigrationVersion int64
	var err error
	if nextDmlMigrationVersion, err = strconv.ParseInt(strings.Split(migration, "_")[0], 10, 64); err != nil {
		logFatal(fmt.Sprintf("Failed determining next DML migration version from file name %q: %v", migration, err))
	}

	f := fmt.Sprintf("%s/%s", dir, migration)
	fileBytes, err := ioutil.ReadFile(f)
	if err != nil {
		logFatal(fmt.Sprintf("Failed reading DML migration file %q: %v", f, err))
	}
	migrationFileString := string(fileBytes)

	migrationData := make(map[string]string)

	tf := fmt.Sprintf("%s/%s", dir, strings.TrimSuffix(migration, ".sql")+".json")
	if _, err := os.Stat(tf); os.IsNotExist(err) {
		logDebug(fmt.Sprintf("No migration data file %q for DML migration file %q", tf, f))

	} else {
		fileBytes, err := ioutil.ReadFile(tf)
		if err != nil {
			logFatal(fmt.Sprintf("Failed reading DML migration data file %q: %v", tf, err))
		}
		if err := json.Unmarshal(fileBytes, &migrationData); err != nil {
			logFatal(fmt.Sprintf("Failed unpacking DML migration data file %q into json: %v", tf, err))
		}
	}

	if len(migrationData) > 0 {
		for k, v := range migrationData {
			migrationFileString = strings.ReplaceAll(migrationFileString, fmt.Sprintf("@%s@", k), v)
		}
	}

	setDataMigrationsDirty(ctx, spannerClient, nextDmlMigrationVersion)

	var statements []spanner.Statement
	for _, v := range strings.Split(migrationFileString, ";") {
		v = replaceWhiteSpaceWithSpace(strings.TrimSpace(v)) + ";"
		if v != ";" {
			statements = append(statements, spanner.Statement{SQL: v})
			logDebug(fmt.Sprintf("-> Created statement from SQL %q", v))
		}
	}
	statements = append(statements, spanner.Statement{
		SQL: "UPDATE DataMigrations	SET Dirty=@dirty WHERE Version=@version",
		Params: map[string]interface{}{
			"dirty":   false,
			"version": nextDmlMigrationVersion,
		},
	})
	statements = append(statements, spanner.Statement{
		SQL: "DELETE FROM DataMigrations WHERE Version=@version",
		Params: map[string]interface{}{
			"version": currentDmlMigrationVersion,
		},
	})
	applyDmlStatements(ctx, spannerClient, currentDmlMigrationVersion, nextDmlMigrationVersion, statements)

	return nextDmlMigrationVersion
}

func applyDmlStatements(ctx context.Context, spannerClient *spanner.Client, currentDmlMigrationVersion, nextDmlMigrationVersion int64, statements []spanner.Statement) {
	logInfo(fmt.Sprintf("Applying DML migration from version '%d' to version '%d': %v", currentDmlMigrationVersion, nextDmlMigrationVersion, statements))

	_, err := spannerClient.ReadWriteTransaction(ctx, func(ctx context.Context, txn *spanner.ReadWriteTransaction) error {
		rowCounts, err := txn.BatchUpdate(ctx, statements)
		if err != nil {
			return err
		}
		logInfo(fmt.Sprintf("Applied DML migration from version '%d' to version '%d'. Updated row counts '%d'", currentDmlMigrationVersion, nextDmlMigrationVersion, rowCounts))
		return nil
	})
	if err != nil {
		logFatal(fmt.Sprintf("Failed applying DML from version '%d' to version '%d': %v", currentDmlMigrationVersion, nextDmlMigrationVersion, err))
	}
}

func setDataMigrationsDirty(ctx context.Context, spannerClient *spanner.Client, version int64) {
	logInfo(fmt.Sprintf("Inserting version '%d' in DataMigrations table as dirty", version))

	_, err := spannerClient.ReadWriteTransaction(ctx, func(ctx context.Context, txn *spanner.ReadWriteTransaction) error {
		stmt := spanner.Statement{
			SQL: "INSERT DataMigrations	(Dirty, Version) VALUES (@dirty, @version)",
			Params: map[string]interface{}{
				"dirty":   true,
				"version": version,
			},
		}
		rowCount, err := txn.Update(ctx, stmt)
		if err != nil {
			return err
		}
		logInfo(fmt.Sprintf("Inserted version '%d' in DataMigrations table as dirty. Updated row count '%d'", version, rowCount))
		return nil
	})
	if err != nil {
		logFatal(fmt.Sprintf("Failed inserting version '%d' in DataMigrations table as dirty: %v", version, err))
	}
}

// SPANNER >--------------------------------------------------
func newSpannerClient(ctx context.Context, databseConnection string) (*spanner.Client, *database.DatabaseAdminClient) {
	logDebug(fmt.Sprintf("Initializing spanner data and admin clients"))

	circleciProjectRepoName := os.Getenv("CIRCLE_PROJECT_REPONAME")
	circleci := circleciProjectRepoName != ""

	var runtimeLabel string
	if circleci {
		runtimeLabel = fmt.Sprintf("%s-%s", circleciProjectRepoName, os.Getenv("CIRCLE_SHA1")[:7])
	} else {
		runtimeLabel = os.Getenv("USER")
	}

	minOpenedSessions := 1
	sessionId := strings.ToLower(pseudoUuid())
	sessionLocation := runtimeLabel

	// If the protocol is not met (https://cloud.google.com/spanner/docs/reference/rpc/google.spanner.v1#session) the following error is generated
	// -> spanner: code = "InvalidArgument", desc = "Invalid CreateSession request."
	spannerClientConfig := spanner.ClientConfig{
		SessionPoolConfig: spanner.SessionPoolConfig{
			MinOpened: uint64(minOpenedSessions),
		},
		SessionLabels: map[string]string{
			"id":       sessionId,
			"location": sessionLocation,
		},
	}

	logDebug(fmt.Sprintf("Creating spanner client using connection string %q, minOpenedSessions '%d', sessionId %q, sessionLocation %q", databseConnection, minOpenedSessions, sessionId, sessionLocation))
	spannerClient, err := spanner.NewClientWithConfig(ctx, databseConnection, spannerClientConfig)
	if err != nil {
		logFatal(fmt.Sprintf("Failed initializing spanner data client for connection %q: %v", databseConnection, err))
	}

	spannerAdminClient, err := database.NewDatabaseAdminClient(ctx)
	if err != nil {
		logFatal(fmt.Sprintf("Failed initializing spanner admin client: %v", err))
	}

	logDebug(fmt.Sprintf("Initialized spanner data and admin clients"))

	return spannerClient, spannerAdminClient
}

// SPANNER <--------------------------------------------------

// CLEANUP >--------------------------------------------------
type Closable interface {
	Close()
}

func cleanUpAndExitOnInterrupt(closables []Closable) {
	c := make(chan os.Signal)
	signal.Notify(c, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-c

		logInfo(fmt.Sprintf("Running clean up"))
		for _, v := range closables {
			v.Close()
		}
		logInfo(fmt.Sprintf("Cleaned"))

		os.Exit(0)
	}()
}

// CLEANUP <--------------------------------------------------

// MISC >--------------------------------------------------
func pseudoUuid() (uuid string) {
	b := make([]byte, 16)
	_, err := rand.Read(b)
	if err != nil {
		logFatal(fmt.Sprintf("Failed gnerating UUID: %v", err))
		return
	}
	uuid = fmt.Sprintf("%X-%X-%X-%X-%X", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
	return
}

func replaceWhiteSpaceWithSpace(str string) string {
	s := strings.Map(func(r rune) rune {
		if unicode.IsSpace(r) {
			return ' '
		}
		return r
	}, str)
	return strings.TrimSpace(strings.Join(strings.Fields(s), " "))
}

// MISC <--------------------------------------------------

// LOGGING >--------------------------------------------------
func newDefaultLogger(debug bool) *logger {
	log.SetFlags(log.Flags() &^ (log.Ldate | log.Ltime))

	return &logger{
		debug:       debug,
		debugLogger: log.New(os.Stdout, fmt.Sprintf("\x1b[%dmDEBUG ", colorDebug), log.Ldate|log.Ltime|log.Lmicroseconds),
		infoLogger:  log.New(os.Stdout, fmt.Sprintf("\x1b[%dmINFO  ", colorInfo), log.Ldate|log.Ltime|log.Lmicroseconds),
		warnLogger:  log.New(os.Stderr, fmt.Sprintf("\x1b[%dmWARN  ", colorWarn), log.Ldate|log.Ltime|log.Lmicroseconds),
		errorLogger: log.New(os.Stderr, fmt.Sprintf("\x1b[%dmERROR ", colorError), log.Ldate|log.Ltime|log.Lmicroseconds),
		fatalLogger: log.New(os.Stderr, fmt.Sprintf("\x1b[%dmFATAL ", colorFatal), log.Ldate|log.Ltime|log.Lmicroseconds),
	}
}

type logger struct {
	debug       bool
	debugLogger *log.Logger
	infoLogger  *log.Logger
	warnLogger  *log.Logger
	errorLogger *log.Logger
	fatalLogger *log.Logger
}

func logDebug(message string) {
	if l.debug {
		doLog(SeverityDebug, message)
	}
}

func logInfo(message string) {
	doLog(SeverityInfo, message)
}

func logNotice(message string) {
	doLog(SeverityNotice, message)
}

func logWarn(message string) {
	doLog(SeverityWarning, message)
}

func logError(message string) {
	doLog(SeverityError, message)
}

func logFatal(message string) {
	doLog(SeverityEmergency, message)
}

func doLog(severity Severity, message string) {
	pc, fileName, lineNumber, _ := runtime.Caller(2)
	line := "line " + strconv.Itoa(lineNumber)
	functionName := runtime.FuncForPC(pc).Name()

	var logger *log.Logger
	switch severity {
	case SeverityDebug:
		logger = l.debugLogger
	case SeverityInfo, SeverityNotice:
		logger = l.infoLogger
	case SeverityWarning:
		logger = l.warnLogger
	case SeverityError:
		logger = l.errorLogger
	case SeverityEmergency:
		logger = l.fatalLogger
		logger.Panicln(fmtStdLog(message, functionName, line, fileName))
		return
	default:
		logger = l.errorLogger
		message = "MISSING LOG LEVEL, USING ERROR => " + message
	}
	logger.Println(fmtStdLog(message, functionName, line, fileName))
}

func fmtStdLog(message, functionName, line, fileName string) string {
	message = fmt.Sprintf("%s %s %s %s", message, functionName, line, fileName)
	return fmt.Sprintf("%s\x1b[0m", message)
}

// LOGGING <--------------------------------------------------
