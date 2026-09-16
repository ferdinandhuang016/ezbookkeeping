package api

import (
	"github.com/mayswind/ezbookkeeping/pkg/core"
	"github.com/mayswind/ezbookkeeping/pkg/errs"
	"github.com/mayswind/ezbookkeeping/pkg/settings"
)

// ClientConfigHandler exposes the same public configuration as the Web client.
// Provider credentials are included only when already exposed by settings.js.
func (a *ServerSettingsApi) ClientConfigHandler(c *core.WebContext) (any, *errs.Error) {
	config := a.CurrentConfig()
	result := map[string]any{
		"syncProtocolVersion":               1,
		"serverVersion":                     core.Version,
		"rootUrl":                           config.RootUrl,
		"enableInternalAuth":                config.EnableInternalAuth,
		"enableOAuth2Login":                 config.EnableOAuth2Login,
		"enableUserRegister":                config.EnableInternalAuth && config.EnableUserRegister,
		"enableUserForgetPassword":          config.EnableInternalAuth && config.EnableUserForgetPassword,
		"enableTwoFactor":                   config.EnableInternalAuth && config.EnableTwoFactor,
		"enableAPIToken":                    config.EnableAPIToken,
		"enableUserVerifyEmail":             config.EnableUserVerifyEmail,
		"enableUserCustomIcon":              config.EnableUserCustomIcon,
		"enableTransactionPictures":         config.EnableTransactionPictures,
		"maxTransactionPictureFileSize":     config.MaxTransactionPictureFileSize,
		"enableScheduledTransaction":        config.EnableScheduledTransaction,
		"enableDataExport":                  config.EnableDataExport,
		"enableDataImport":                  config.EnableDataImport,
		"enableMCPServer":                   config.EnableMCPServer,
		"oauth2Provider":                    config.OAuth2Provider,
		"transactionFromAITextRecognition":  config.TransactionFromAITextRecognition && config.TextRecognitionLLMConfig != nil && config.TextRecognitionLLMConfig.LLMProvider != "",
		"transactionFromAIImageRecognition": config.TransactionFromAIImageRecognition && config.ReceiptImageRecognitionLLMConfig != nil && config.ReceiptImageRecognitionLLMConfig.LLMProvider != "",
		"mapProvider":                       config.MapProvider,
		"exchangeRatesRequestTimeout":       config.ExchangeRatesRequestTimeout,
	}
	publicContent := func(value settings.MultiLanguageContentConfig) map[string]string {
		content := map[string]string{"default": value.DefaultContent}
		for language, text := range value.MultiLanguageContent {
			content[language] = text
		}
		return content
	}
	if config.LoginPageTips.Enabled {
		result["loginPageTips"] = publicContent(config.LoginPageTips)
	}
	if config.OAuth2Provider == settings.OAuth2ProviderOIDC && config.OAuth2OIDCCustomDisplayNameConfig.Enabled {
		result["oauth2CustomDisplayNames"] = publicContent(config.OAuth2OIDCCustomDisplayNameConfig)
	}
	proxy := config.EnableMapDataFetchProxy && (config.MapProvider == settings.OpenStreetMapProvider || config.MapProvider == settings.OpenStreetMapHumanitarianStyleProvider || config.MapProvider == settings.OpenTopoMapProvider || config.MapProvider == settings.OPNVKarteMapProvider || config.MapProvider == settings.CyclOSMMapProvider || config.MapProvider == settings.CartoDBMapProvider || config.MapProvider == settings.TomTomMapProvider || config.MapProvider == settings.TianDiTuProvider || config.MapProvider == settings.CustomProvider)
	result["enableMapDataFetchProxy"] = proxy
	if config.MapProvider == settings.CustomProvider {
		result["customMapMinZoomLevel"], result["customMapMaxZoomLevel"], result["customMapDefaultZoomLevel"] = config.CustomMapTileServerMinZoomLevel, config.CustomMapTileServerMaxZoomLevel, config.CustomMapTileServerDefaultZoomLevel
		if !proxy {
			result["customMapTileLayerUrl"], result["customMapAnnotationLayerUrl"] = config.CustomMapTileServerTileLayerUrl, config.CustomMapTileServerAnnotationLayerUrl
		} else {
			result["customMapAnnotationLayerDataFetchProxy"] = config.CustomMapTileServerAnnotationLayerUrl != ""
		}
	}
	if config.MapProvider == settings.TomTomMapProvider && !proxy {
		result["tomTomMapAPIKey"] = config.TomTomMapAPIKey
	}
	if config.MapProvider == settings.TianDiTuProvider && !proxy {
		result["tianDiTuAPIKey"] = config.TianDiTuAPIKey
	}
	if config.MapProvider == settings.GoogleMapProvider {
		result["googleMapAPIKey"] = config.GoogleMapAPIKey
	}
	if config.MapProvider == settings.BaiduMapProvider {
		result["baiduMapAK"] = config.BaiduMapAK
	}
	if config.MapProvider == settings.AmapProvider {
		result["amapApplicationKey"], result["amapSecurityVerificationMethod"] = config.AmapApplicationKey, config.AmapSecurityVerificationMethod
		if config.AmapSecurityVerificationMethod == settings.AmapSecurityVerificationExternalProxyMethod {
			result["amapApiExternalProxyUrl"] = config.AmapApiExternalProxyUrl
		}
		if config.AmapSecurityVerificationMethod == settings.AmapSecurityVerificationPlainTextMethod {
			result["amapApplicationSecret"] = config.AmapApplicationSecret
		}
	}
	return result, nil
}
