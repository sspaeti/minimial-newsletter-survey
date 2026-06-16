package server

import (
	"embed"
	"html/template"
	"log"
	"net"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/sspaeti/minimal-newsletter-survey/internal/store"
	"github.com/sspaeti/minimal-newsletter-survey/internal/voter"
)

type Config struct {
	DBPath     string
	HTTPAddr   string
	QuackAddr  string
	QuackToken string
	BlogURL    string
}

//go:embed thanks.html result.html
var staticFS embed.FS

// Route patterns. Edit here if the URL shape ever changes — the rest of the
// file uses these constants so any path change is a single edit. The vote
// patterns use Go 1.22 ServeMux wildcards; r.PathValue("id") and
// r.PathValue("answer") pull the segments inside the handler.
const (
	routeVote       = "/{id}/{answer}"        // primary, short form (e.g. q.ssp.sh/init/awesome)
	routeVoteLegacy = "/survey/{id}/{answer}" // kept so old newsletter links keep working
	routeResult     = "/result/{id}"          // server-rendered tally page
	routeThanks     = "/thanks"
	routeHealth     = "/healthz"
)

// slugRe gates both survey_id and answer. Lowercase alnum, dash, underscore,
// must start with alnum, max 64 chars. Keeps the URL space clean and the
// table free of arbitrary user-supplied data.
var slugRe = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,63}$`)

// botUASubstrings matches common link unfurlers, RSS readers, search
// crawlers, headless-browser link checkers, and security scanners that
// fetch the URL with GET but do not represent a human click. Matched
// case-insensitively as substrings against the User-Agent header.
//
// Refine this list when a new platform shows up in the vote tally with
// suspicious volume — re-deploy and re-test. Order does not matter.
var botUASubstrings = []string{
	// Social media link unfurlers
	"twitterbot", "facebookexternalhit", "linkedinbot", "slackbot",
	"slack-imgproxy", "discordbot", "telegrambot", "whatsapp",
	"skypeuripreview", "redditbot", "pinterestbot", "applebot", "tumblr",
	"cardyb", "bsky", "bluesky", "mastodon", "akkoma", "pleroma",
	"fediverse",
	// Search-engine + SEO crawlers
	"googlebot", "bingbot", "yandex", "duckduckbot", "baiduspider",
	"ahrefsbot", "semrushbot", "mj12bot", "petalbot",
	// Headless browser link checkers
	"headlesschrome", "phantomjs", "puppeteer", "selenium", "playwright",
	"lighthouse",
	// RSS / feed readers
	"feedfetcher", "rssbot", "inoreader", "feedly", "newsblur",
	// Generic HTTP clients (bots rarely customise these)
	"curl/", "wget/", "python-requests", "python-urllib",
	"go-http-client", "okhttp", "java/", "apache-httpclient", "httpx",
	"node-fetch", "axios/",
	// Security / Safe-Links / URL scanners
	"safelinks", "urlscan", "virustotal", "phishtank",
	// Generic bot markers
	"bot/", "crawler", "spider", "scraper", "preview",
}

// isBotUA returns true for User-Agent strings that look like automation
// rather than a human-driven browser. An empty UA also counts — every
// mainstream browser sends one.
func isBotUA(ua string) bool {
	if ua == "" {
		return true
	}
	ua = strings.ToLower(ua)
	for _, sub := range botUASubstrings {
		if strings.Contains(ua, sub) {
			return true
		}
	}
	return false
}

type Server struct {
	cfg    Config
	store  *store.Store
	salt   *voter.Salt
	thanks *template.Template
	result *template.Template
}

func New(cfg Config, st *store.Store) *Server {
	return &Server{
		cfg:    cfg,
		store:  st,
		salt:   voter.NewSalt(),
		thanks: template.Must(template.ParseFS(staticFS, "thanks.html")),
		result: template.Must(template.ParseFS(staticFS, "result.html")),
	}
}

func (s *Server) ListenAndServe() error {
	mux := http.NewServeMux()
	// Order doesn't matter for Go 1.22 ServeMux — more specific patterns
	// always win. /result/{id} beats /{id}/{answer} for paths under /result/.
	mux.HandleFunc(routeResult, s.handleResult)
	mux.HandleFunc(routeVote, s.handleSurvey)
	mux.HandleFunc(routeVoteLegacy, s.handleSurvey)
	mux.HandleFunc(routeThanks, s.handleThanks)
	mux.HandleFunc(routeHealth, func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte("ok"))
	})

	httpServer := &http.Server{
		Addr:              s.cfg.HTTPAddr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	return httpServer.ListenAndServe()
}

func (s *Server) handleSurvey(w http.ResponseWriter, r *http.Request) {
	// Email scanners (Microsoft Safe Links, Gmail prefetch) issue HEAD before
	// the user actually clicks. Reply 200 but do not record.
	if r.Method == http.MethodHead {
		w.WriteHeader(http.StatusOK)
		return
	}
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	surveyID := r.PathValue("id")
	answer := r.PathValue("answer")
	if !slugRe.MatchString(surveyID) || !slugRe.MatchString(answer) {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}

	ua := r.Header.Get("User-Agent")
	// Social-media link unfurlers, RSS readers, security scanners, etc. fetch
	// the URL with GET (not HEAD), so this is needed in addition to the HEAD
	// guard above. Reply 200 but do not record.
	if isBotUA(ua) {
		log.Printf("bot-skip survey_id=%s answer=%s", surveyID, answer)
		w.WriteHeader(http.StatusOK)
		return
	}

	ip := clientIP(r)
	vh := voter.Hash(ip, ua, surveyID, s.salt.Current())

	if err := s.store.RecordVote(surveyID, answer, vh); err != nil {
		log.Printf("record vote: survey=%s err=%v", surveyID, err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	log.Printf("vote survey_id=%s answer=%s", surveyID, answer)
	http.Redirect(w, r, "/thanks?id="+surveyID, http.StatusFound)
}

func (s *Server) handleThanks(w http.ResponseWriter, r *http.Request) {
	data := struct {
		BlogURL  string
		SurveyID string
	}{
		BlogURL:  s.cfg.BlogURL,
		SurveyID: r.URL.Query().Get("id"),
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	if err := s.thanks.Execute(w, data); err != nil {
		log.Printf("thanks template: %v", err)
	}
}

// tallyRow is the view-model passed to result.html — Tally as it comes out
// of the store, plus a PercentOfMax we computed for the CSS bar width.
type tallyRow struct {
	Answer       string
	Clicks       int
	PercentOfMax int
}

type resultPageData struct {
	SurveyID   string
	Tallies    []tallyRow
	TotalVotes int
	BlogURL    string
}

func (s *Server) handleResult(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodHead {
		w.WriteHeader(http.StatusOK)
		return
	}
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	surveyID := r.PathValue("id")
	if !slugRe.MatchString(surveyID) {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}

	rows, err := s.store.TallyBySurvey(surveyID)
	if err != nil {
		log.Printf("tally survey_id=%s err=%v", surveyID, err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	total, top := 0, 0
	for _, t := range rows {
		total += t.Clicks
		if t.Clicks > top {
			top = t.Clicks
		}
	}
	view := make([]tallyRow, len(rows))
	for i, t := range rows {
		pct := 0
		if top > 0 {
			pct = (t.Clicks * 100) / top
		}
		view[i] = tallyRow{Answer: t.Answer, Clicks: t.Clicks, PercentOfMax: pct}
	}

	data := resultPageData{
		SurveyID:   surveyID,
		Tallies:    view,
		TotalVotes: total,
		BlogURL:    s.cfg.BlogURL,
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	if err := s.result.Execute(w, data); err != nil {
		log.Printf("result template: %v", err)
	}
}

// clientIP picks the first hop from X-Forwarded-For (set by Caddy) and falls
// back to RemoteAddr. The IP is only used as one input to the voter hash; it
// is never persisted.
func clientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		if i := strings.Index(xff, ","); i > 0 {
			return strings.TrimSpace(xff[:i])
		}
		return strings.TrimSpace(xff)
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
