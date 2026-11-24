(() => {
  'use strict';

  const production = 'https://crewsignal.org';
  if (location.origin !== production || window.parent === window) return;

  const measurementId = 'G-JM4GBY4EQY';
  const denied = {
    analytics_storage: 'denied',
    ad_storage: 'denied',
    ad_user_data: 'denied',
    ad_personalization: 'denied',
  };

  function activate(event) {
    if (event.origin !== production || event.source !== window.parent) return;
    const page = event.data?.page;
    if (typeof page !== 'string' || !/^\/(?!\/)[a-zA-Z0-9._~%/-]*$/.test(page)) return;
    try {
      if (localStorage.getItem('crewsignal.analytics-consent.v1') !== 'accepted') return;
    } catch {
      return;
    }
    window.removeEventListener('message', activate);

    window.dataLayer = [];
    function gtag() {
      window.dataLayer.push(arguments);
    }
    gtag('consent', 'default', denied);
    gtag('consent', 'update', { ...denied, analytics_storage: 'granted' });
    gtag('set', 'ads_data_redaction', true);
    gtag('set', 'url_passthrough', false);
    const settings = {
      send_page_view: false,
      page_location: production + page,
      page_referrer: '',
      page_title: 'CrewSignal',
      ignore_referrer: true,
      allow_google_signals: false,
      allow_enhanced_conversions: false,
      allow_display_features: false,
      allow_ad_personalization_signals: false,
      cookie_domain: 'none',
      cookie_expires: 90 * 24 * 60 * 60,
      cookie_update: false,
      cookie_flags: 'SameSite=Strict;Secure',
    };
    // Configure before the js lifecycle command so this destination uses our first config.
    gtag('set', settings);
    gtag('config', measurementId, settings);
    gtag('js', new Date());
    gtag('event', 'page_view', {
      page_location: settings.page_location,
      page_referrer: settings.page_referrer,
      send_to: measurementId,
    });

    const tag = document.createElement('script');
    tag.async = true;
    tag.referrerPolicy = 'no-referrer';
    tag.src = 'https://www.googletagmanager.com/gtag/js?id=' + measurementId;
    document.head.append(tag);
  }

  window.addEventListener('message', activate);
})();
