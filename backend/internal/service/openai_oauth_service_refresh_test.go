package service

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/pkg/openai"
	"github.com/imroc/req/v3"
	"github.com/stretchr/testify/require"
)

type openaiOAuthClientRefreshStub struct {
	refreshCalls int32
}

func (s *openaiOAuthClientRefreshStub) ExchangeCode(ctx context.Context, code, codeVerifier, redirectURI, proxyURL, clientID string) (*openai.TokenResponse, error) {
	return nil, errors.New("not implemented")
}

func (s *openaiOAuthClientRefreshStub) RefreshToken(ctx context.Context, refreshToken, proxyURL string) (*openai.TokenResponse, error) {
	atomic.AddInt32(&s.refreshCalls, 1)
	return nil, errors.New("not implemented")
}

func (s *openaiOAuthClientRefreshStub) RefreshTokenWithClientID(ctx context.Context, refreshToken, proxyURL string, clientID string) (*openai.TokenResponse, error) {
	atomic.AddInt32(&s.refreshCalls, 1)
	return nil, errors.New("not implemented")
}

type rewriteTransport struct {
	handler http.Handler
}

func (t rewriteTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	rec := &responseRecorder{
		header: make(http.Header),
		body:   make([]byte, 0),
		code:   http.StatusOK,
	}
	t.handler.ServeHTTP(rec, req)
	return &http.Response{
		StatusCode: rec.code,
		Status:     http.StatusText(rec.code),
		Header:     rec.header.Clone(),
		Body:       io.NopCloser(bytes.NewReader(rec.body)),
		Request:    req,
	}, nil
}

type responseRecorder struct {
	header http.Header
	body   []byte
	code   int
}

func (r *responseRecorder) Header() http.Header {
	return r.header
}

func (r *responseRecorder) Write(data []byte) (int, error) {
	r.body = append(r.body, data...)
	return len(data), nil
}

func (r *responseRecorder) WriteHeader(statusCode int) {
	r.code = statusCode
}

func TestOpenAIOAuthService_RefreshAccountToken_NoRefreshTokenUsesExistingAccessToken(t *testing.T) {
	client := &openaiOAuthClientRefreshStub{}
	svc := NewOpenAIOAuthService(nil, client)

	expiresAt := time.Now().Add(30 * time.Minute).UTC().Format(time.RFC3339)
	account := &Account{
		ID:       77,
		Platform: PlatformOpenAI,
		Type:     AccountTypeOAuth,
		Credentials: map[string]any{
			"access_token": "existing-access-token",
			"expires_at":   expiresAt,
			"client_id":    "client-id-1",
		},
	}

	info, err := svc.RefreshAccountToken(context.Background(), account)
	require.NoError(t, err)
	require.NotNil(t, info)
	require.Equal(t, "existing-access-token", info.AccessToken)
	require.Equal(t, "client-id-1", info.ClientID)
	require.Zero(t, atomic.LoadInt32(&client.refreshCalls), "existing access token should be reused without calling refresh")
}

func TestOpenAIOAuthService_RefreshAccountToken_NoRefreshTokenEnrichesExistingAccessToken(t *testing.T) {
	client := &openaiOAuthClientRefreshStub{}
	svc := NewOpenAIOAuthService(nil, client)
	svc.SetPrivacyClientFactory(func(proxyURL string) (*req.Client, error) {
		httpClient := req.C()
		httpClient.GetClient().Transport = rewriteTransport{
			handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch {
				case r.Method == http.MethodGet && r.URL.Path == "/backend-api/accounts/check/v4-2023-04-27":
					w.Header().Set("Content-Type", "application/json")
					_, _ = w.Write([]byte(`{
						"accounts": {
							"org-1": {
								"account": { "plan_type": "plus", "is_default": true },
								"entitlement": { "expires_at": "2026-05-09T11:37:47+00:00" }
							}
						}
					}`))
				case r.Method == http.MethodPatch && r.URL.Path == "/backend-api/settings/account_user_setting":
					w.WriteHeader(http.StatusOK)
					_, _ = w.Write([]byte(`{}`))
				default:
					w.WriteHeader(http.StatusNotFound)
				}
			}),
		}
		return httpClient, nil
	})

	expiresAt := time.Now().Add(30 * time.Minute).UTC().Format(time.RFC3339)
	account := &Account{
		ID:       78,
		Platform: PlatformOpenAI,
		Type:     AccountTypeOAuth,
		Credentials: map[string]any{
			"access_token":    "existing-access-token",
			"expires_at":      expiresAt,
			"client_id":       "client-id-1",
			"organization_id": "org-1",
		},
	}

	info, err := svc.RefreshAccountToken(context.Background(), account)
	require.NoError(t, err)
	require.NotNil(t, info)
	require.Equal(t, "plus", info.PlanType)
	require.Equal(t, "2026-05-09T11:37:47+00:00", info.SubscriptionExpiresAt)
	require.Zero(t, atomic.LoadInt32(&client.refreshCalls), "existing access token should be reused without calling refresh")
}

func TestOpenAITokenRefresher_NeedsRefresh_SkipsAccountWithoutRefreshToken(t *testing.T) {
	refresher := NewOpenAITokenRefresher(nil, nil)
	expiresAt := time.Now().Add(time.Minute).UTC().Format(time.RFC3339)

	withoutRT := &Account{
		Platform: PlatformOpenAI,
		Type:     AccountTypeOAuth,
		Credentials: map[string]any{
			"access_token": "access-token",
			"expires_at":   expiresAt,
		},
	}
	require.False(t, refresher.NeedsRefresh(withoutRT, 5*time.Minute))

	withRT := &Account{
		Platform: PlatformOpenAI,
		Type:     AccountTypeOAuth,
		Credentials: map[string]any{
			"access_token":  "access-token",
			"refresh_token": "refresh-token",
			"expires_at":    expiresAt,
		},
	}
	require.True(t, refresher.NeedsRefresh(withRT, 5*time.Minute))
}

func TestOpenAITokenProvider_NoRefreshTokenExpiredAccessTokenReturnsError(t *testing.T) {
	provider := NewOpenAITokenProvider(nil, nil, nil)
	expiresAt := time.Now().Add(-time.Minute).UTC().Format(time.RFC3339)
	account := &Account{
		Platform: PlatformOpenAI,
		Type:     AccountTypeOAuth,
		Credentials: map[string]any{
			"access_token": "expired-access-token",
			"expires_at":   expiresAt,
		},
	}

	token, err := provider.GetAccessToken(context.Background(), account)
	require.Error(t, err)
	require.Empty(t, token)
	require.Contains(t, err.Error(), "refresh_token is missing")
}
