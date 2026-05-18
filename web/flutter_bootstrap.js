{{flutter_js}}
{{flutter_build_config}}

(function () {
  const shellId = 'globos-web-shell';
  const body = document.body;
  const searchParams = new URLSearchParams(window.location.search);

  const requestedRenderer = searchParams.get('renderer');
  const useCpuOnlyCanvasKit =
    searchParams.get('cpuOnly') === '1' ||
    searchParams.get('cpuOnly') === 'true';
  const forceSingleThreadedSkwasm =
    searchParams.get('singleThreadedSkwasm') === '1' ||
    searchParams.get('singleThreadedSkwasm') === 'true';

  const flutterLoaderConfig = {};
  if (
    requestedRenderer === 'canvaskit' ||
    requestedRenderer === 'skwasm'
  ) {
    flutterLoaderConfig.renderer = requestedRenderer;
  }
  if (requestedRenderer === 'canvaskit' && useCpuOnlyCanvasKit) {
    flutterLoaderConfig.renderer = 'canvaskit';
    flutterLoaderConfig.canvasKitForceCpuOnly = true;
  }
  if (forceSingleThreadedSkwasm) {
    flutterLoaderConfig.renderer = 'skwasm';
    flutterLoaderConfig.forceSingleThreadedSkwasm = true;
  }

  const injectShellStyles = () => {
    if (document.getElementById('globos-web-shell-styles')) {
      return;
    }

    const style = document.createElement('style');
    style.id = 'globos-web-shell-styles';
    style.textContent = `
      html, body {
        background: #F5F7FA;
        color: #111827;
        margin: 0;
        min-height: 100%;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      }

      #${shellId} {
        position: fixed;
        inset: 0;
        display: flex;
        align-items: center;
        justify-content: center;
        padding: 32px;
        background: #F5F7FA;
        z-index: 9999;
      }

      #${shellId}[data-hidden="true"] {
        display: none;
      }

      .globos-web-shell__panel {
        width: min(480px, 100%);
        padding: 28px;
        border: 1px solid #E5E7EB;
        border-radius: 20px;
        background: #FFFFFF;
        box-shadow: 0 18px 48px rgba(15, 23, 42, 0.08);
      }

      .globos-web-shell__eyebrow {
        margin: 0 0 12px;
        color: #2563EB;
        font-size: 12px;
        font-weight: 700;
        letter-spacing: 0.08em;
        text-transform: uppercase;
      }

      .globos-web-shell__title {
        margin: 0;
        color: #111827;
        font-size: 28px;
        font-weight: 700;
        line-height: 1.1;
      }

      .globos-web-shell__body {
        margin: 12px 0 0;
        color: #6B7280;
        font-size: 14px;
        line-height: 1.6;
      }

      .globos-web-shell__status {
        margin-top: 18px;
        display: inline-flex;
        align-items: center;
        gap: 10px;
        color: #111827;
        font-size: 13px;
        font-weight: 600;
      }

      .globos-web-shell__dot {
        width: 10px;
        height: 10px;
        border-radius: 999px;
        background: #2563EB;
        animation: globos-web-shell-pulse 1.2s ease-in-out infinite;
      }

      .globos-web-shell__hint {
        margin-top: 20px;
        padding: 14px 16px;
        border-radius: 14px;
        background: #F1F4F8;
        color: #6B7280;
        font-size: 13px;
        line-height: 1.5;
      }

      .globos-web-shell__hint code {
        color: #111827;
        font-family: ui-monospace, "SFMono-Regular", monospace;
        font-size: 12px;
      }

      .globos-web-shell__hint--error {
        border-left: 4px solid #DC2626;
        background: #FEF2F2;
        color: #991B1B;
      }

      @keyframes globos-web-shell-pulse {
        0%, 100% { opacity: 1; transform: scale(1); }
        50% { opacity: 0.45; transform: scale(0.9); }
      }
    `;
    document.head.appendChild(style);
  };

  const renderShell = ({
    title,
    bodyText,
    statusText,
    hintText,
    hintClassName = '',
  }) => {
    injectShellStyles();

    let shell = document.getElementById(shellId);
    if (!shell) {
      shell = document.createElement('div');
      shell.id = shellId;
      body.appendChild(shell);
    }

    shell.dataset.hidden = 'false';
    shell.innerHTML = `
      <div class="globos-web-shell__panel">
        <p class="globos-web-shell__eyebrow">GLOBOS POS</p>
        <h1 class="globos-web-shell__title">${title}</h1>
        <p class="globos-web-shell__body">${bodyText}</p>
        <div class="globos-web-shell__status">
          <span class="globos-web-shell__dot"></span>
          <span>${statusText}</span>
        </div>
        ${hintText ? `<div class="globos-web-shell__hint ${hintClassName}">${hintText}</div>` : ''}
      </div>
    `;
  };

  const hideShell = () => {
    const shell = document.getElementById(shellId);
    if (shell) {
      shell.dataset.hidden = 'true';
    }
  };

  const hasFlutterView = () =>
    Boolean(
      document.querySelector('flutter-view') ||
          document.querySelector('flt-glass-pane') ||
          document.querySelector('flt-semantics-placeholder')
    );

  let bootCompleted = false;
  let bootFailed = false;
  let lastBootstrapError = null;

  const failShell = (message) => {
    if (bootCompleted || bootFailed) {
      return;
    }
    bootFailed = true;
    renderShell({
      title: 'Web renderer did not start',
      bodyText:
          'This browser session could not initialize the default Flutter web renderer for GLOBOS POS.',
      statusText: 'Renderer startup failed',
      hintText:
          `${message ? `${message}<br><br>` : ''}If this machine keeps losing the WebGL context, run <code>flutter run -d chrome --web-port 3000 --wasm</code> for verification.`,
      hintClassName: 'globos-web-shell__hint--error',
    });
  };

  window.addEventListener('error', (event) => {
    lastBootstrapError = event.error || event.message || 'Unknown web bootstrap error';
  });
  window.addEventListener('unhandledrejection', (event) => {
    lastBootstrapError = event.reason || 'Unhandled promise rejection during Flutter bootstrap';
  });
  window.addEventListener('webglcontextlost', () => {
    lastBootstrapError = 'WebGL context lost while initializing Flutter web.';
  });

  renderShell({
    title: 'Preparing operational workspace',
    bodyText:
        'Starting GLOBOS POS and loading the current store context for this browser session.',
    statusText: 'Initializing Flutter web runtime',
    hintText: 'If startup stalls on this machine, verify with <code>flutter run -d chrome --web-port 3000 --wasm</code>.',
  });

  const bootWatchdog = window.setTimeout(() => {
    if (!bootCompleted && !hasFlutterView()) {
      failShell(lastBootstrapError ? String(lastBootstrapError) : '');
    }
  }, 12000);

  const observer = new MutationObserver(() => {
    if (hasFlutterView()) {
      bootCompleted = true;
      window.clearTimeout(bootWatchdog);
      observer.disconnect();
      hideShell();
    }
  });

  observer.observe(document.documentElement, {
    childList: true,
    subtree: true,
  });

  _flutter.loader.load({
    config: flutterLoaderConfig,
    onEntrypointLoaded: async (engineInitializer) => {
      const appRunner = await engineInitializer.initializeEngine(
        flutterLoaderConfig,
      );
      await appRunner.runApp();
      bootCompleted = true;
      window.clearTimeout(bootWatchdog);
      hideShell();
      observer.disconnect();
    },
  }).catch((error) => {
    lastBootstrapError = error;
    failShell(String(error));
  });
})();
