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

//go:embed thanks.html result.html landing.html style.css ogimage.png
var staticFS embed.FS

// Route patterns. Edit here if the URL shape ever changes — the rest of the
// file uses these constants so any path change is a single edit. The vote
// patterns use Go 1.22 ServeMux wildcards; r.PathValue("id") and
// r.PathValue("answer") pull the segments inside the handler.
const (
	routeVote          = "/{id}/{answer}"        // primary, short form (e.g. q.ssp.sh/init/awesome)
	routeVoteLegacy    = "/survey/{id}/{answer}" // kept so old newsletter links keep working
	routeResult        = "/result/{id}"          // server-rendered tally page
	routeLanding       = "/{id}"                 // landing page with answer buttons for registered surveys
	routeLandingLegacy = "/survey/{id}"          // alias matching the explicit /survey/ form the user might type
	routeThanks        = "/thanks"
	routeHealth        = "/healthz"
	routeStyle         = "/style.css"    // shared CSS for thanks.html + result.html
	routeOGImage       = "/og-image.png" // generic social-card image for result.html
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
	cfg     Config
	store   *store.Store
	salt    *voter.Salt
	thanks  *template.Template
	result  *template.Template
	landing *template.Template
	css     []byte // cached at startup, served from routeStyle
	ogImage []byte // cached at startup, served from routeOGImage
}

func New(cfg Config, st *store.Store) *Server {
	css, err := staticFS.ReadFile("style.css")
	if err != nil {
		panic("embedded style.css missing: " + err.Error())
	}
	ogImage, err := staticFS.ReadFile("ogimage.png")
	if err != nil {
		panic("embedded ogimage.png missing: " + err.Error())
	}
	return &Server{
		cfg:     cfg,
		store:   st,
		salt:    voter.NewSalt(),
		thanks:  template.Must(template.ParseFS(staticFS, "thanks.html")),
		result:  template.Must(template.ParseFS(staticFS, "result.html")),
		landing: template.Must(template.ParseFS(staticFS, "landing.html")),
		css:     css,
		ogImage: ogImage,
	}
}

func (s *Server) ListenAndServe() error {
	mux := http.NewServeMux()
	// Order doesn't matter for Go 1.22 ServeMux — more specific patterns
	// always win. /result/{id} beats /{id}/{answer} for paths under /result/.
	mux.HandleFunc(routeResult, s.handleResult)
	mux.HandleFunc(routeVote, s.handleSurvey)
	mux.HandleFunc(routeVoteLegacy, s.handleSurvey)
	mux.HandleFunc(routeLanding, s.handleLanding)
	mux.HandleFunc(routeLandingLegacy, s.handleLanding)
	mux.HandleFunc(routeThanks, s.handleThanks)
	mux.HandleFunc(routeStyle, s.handleStyle)
	mux.HandleFunc(routeOGImage, s.handleOGImage)
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

	// Optional per-survey answer allowlist. Populated by `make survey-create`
	// (writes a row into the `surveys` table via Quack). If the survey isn't
	// registered, GetAllowedAnswers returns nil and we stay in open mode —
	// any slug-valid answer counts. If it IS registered, only listed answers
	// are recorded; anything else returns 200 without writing, same shape as
	// the bot-skip path above.
	allowed, err := s.store.GetAllowedAnswers(surveyID)
	if err != nil {
		log.Printf("allowed-answers lookup: survey_id=%s err=%v", surveyID, err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	if allowed != nil && !allowed[answer] {
		log.Printf("answer-reject survey_id=%s answer=%s", surveyID, answer)
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

func (s *Server) handleStyle(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "text/css; charset=utf-8")
	w.Header().Set("Cache-Control", "public, max-age=3600")
	if r.Method == http.MethodHead {
		w.WriteHeader(http.StatusOK)
		return
	}
	w.Write(s.css)
}

func (s *Server) handleOGImage(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "image/png")
	// Long cache: this is a static asset that only changes on redeploy. Social
	// scrapers (Twitter/FB/LinkedIn) cache aggressively anyway.
	w.Header().Set("Cache-Control", "public, max-age=86400")
	if r.Method == http.MethodHead {
		w.WriteHeader(http.StatusOK)
		return
	}
	w.Write(s.ogImage)
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
	SurveyID      string
	Tallies       []tallyRow
	TotalVotes    int
	BlogURL       string
	PageURL       string // absolute URL of this result page, for og:url
	OGImageURL    string // absolute URL of the social-card image, for og:image
	OGTitle       string
	OGDescription string
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

	base := publicBaseURL(r)
	data := resultPageData{
		SurveyID:      surveyID,
		Tallies:       view,
		TotalVotes:    total,
		BlogURL:       s.cfg.BlogURL,
		PageURL:       base + r.URL.Path,
		OGImageURL:    base + routeOGImage,
		OGTitle:       "Survey results: " + surveyID,
		OGDescription: "Live tally of newsletter reader ratings for " + surveyID + ".",
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	if err := s.result.Execute(w, data); err != nil {
		log.Printf("result template: %v", err)
	}
}

// landingAnswer is one button on the landing page — the slug (URL segment
// part) and a human-friendly Label derived from the slug.
type landingAnswer struct {
	Slug  string
	Label string
}

type landingPageData struct {
	SurveyID      string
	Answers       []landingAnswer
	PageURL       string
	OGImageURL    string
	OGTitle       string
	OGDescription string
}

// handleLanding serves /{id} and /survey/{id} — the public vote landing page
// that lists the registered answer slugs as buttons. Only renders for
// surveys that have a row in the `surveys` table; unregistered (open-mode)
// surveys 404 so we don't accidentally expose a wildcard "anyone can guess
// a slug" landing.
func (s *Server) handleLanding(w http.ResponseWriter, r *http.Request) {
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
		http.NotFound(w, r)
		return
	}

	answers, err := s.store.GetSurveyAnswers(surveyID)
	if err != nil {
		log.Printf("survey answers lookup: survey_id=%s err=%v", surveyID, err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	if answers == nil {
		// Unregistered survey — no landing page to show.
		http.NotFound(w, r)
		return
	}

	links := make([]landingAnswer, len(answers))
	for i, a := range answers {
		links[i] = landingAnswer{Slug: a, Label: titleAnswer(a)}
	}

	base := publicBaseURL(r)
	data := landingPageData{
		SurveyID:      surveyID,
		Answers:       links,
		PageURL:       base + r.URL.Path,
		OGImageURL:    base + routeOGImage,
		OGTitle:       "Vote: " + surveyID,
		OGDescription: "One click to record your rating for newsletter " + surveyID + ".",
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	if err := s.landing.Execute(w, data); err != nil {
		log.Printf("landing template: %v", err)
	}
}

// titleAnswer turns a slug like "not-sure" into a display label "Not Sure".
// Validation upstream guarantees slugs are lower-case ASCII so byte-indexing
// the first rune of each part is safe.
func titleAnswer(slug string) string {
	parts := strings.Split(slug, "-")
	for i, p := range parts {
		if len(p) > 0 {
			parts[i] = strings.ToUpper(p[:1]) + p[1:]
		}
	}
	return strings.Join(parts, " ")
}

// publicBaseURL returns the scheme+host that an external client used to reach
// us — needed for absolute URLs in og: tags (social scrapers reject relative
// URLs). Trusts X-Forwarded-Proto from the upstream reverse proxy; defaults to
// https since this app only ships behind TLS termination in real deployments.
func publicBaseURL(r *http.Request) string {
	scheme := "https"
	if p := r.Header.Get("X-Forwarded-Proto"); p != "" {
		scheme = p
	}
	return scheme + "://" + r.Host
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
