{{flutter_js}}
{{flutter_build_config}}

(function () {
  const shellId = 'globos-web-shell';
  const body = document.body;
  const searchParams = new URLSearchParams(window.location.search);
  const isQrOrderRoute =
    window.location.hash.startsWith('#/qr/') ||
    window.location.pathname.startsWith('/qr/');

  const languageCode = (navigator.language || 'en').toLowerCase();
  const language = languageCode.startsWith('ko')
    ? 'ko'
    : languageCode.startsWith('vi')
      ? 'vi'
      : 'en';

  const shellCopy = {
    ko: {
      qr: {
        title: '주문 화면을 준비하고 있습니다',
        body: '메뉴를 불러오는 동안 잠시만 기다려 주세요.',
        status: '메뉴 불러오는 중',
        errorTitle: '주문 화면을 열 수 없습니다',
        errorBody: '주문 화면을 불러오는 중 문제가 발생했습니다.',
        errorStatus: '연결 확인 필요',
        errorHint:
          '인터넷 연결을 확인한 후 페이지를 새로고침해 주세요. 계속 문제가 발생하면 매장 직원에게 문의해 주세요.',
      },
      staff: {
        title: '매장 운영 화면을 준비하고 있습니다',
        body: '현재 매장 정보를 불러오는 동안 잠시만 기다려 주세요.',
        status: '운영 화면 불러오는 중',
        errorTitle: '운영 화면을 열 수 없습니다',
        errorBody: '매장 운영 화면을 불러오는 중 문제가 발생했습니다.',
        errorStatus: '연결 확인 필요',
        errorHint:
          '인터넷 연결을 확인한 후 페이지를 새로고침해 주세요. 계속 문제가 발생하면 시스템 관리자에게 문의해 주세요.',
      },
    },
    vi: {
      qr: {
        title: 'Đang chuẩn bị trang gọi món',
        body: 'Vui lòng chờ trong khi hệ thống tải thực đơn.',
        status: 'Đang tải thực đơn',
        errorTitle: 'Không thể mở trang gọi món',
        errorBody: 'Đã xảy ra sự cố khi tải trang gọi món.',
        errorStatus: 'Vui lòng kiểm tra kết nối',
        errorHint:
          'Hãy kiểm tra kết nối Internet và tải lại trang. Nếu sự cố vẫn tiếp diễn, vui lòng liên hệ nhân viên cửa hàng.',
      },
      staff: {
        title: 'Đang chuẩn bị màn hình vận hành',
        body: 'Vui lòng chờ trong khi hệ thống tải thông tin cửa hàng.',
        status: 'Đang tải màn hình vận hành',
        errorTitle: 'Không thể mở màn hình vận hành',
        errorBody: 'Đã xảy ra sự cố khi tải màn hình vận hành cửa hàng.',
        errorStatus: 'Vui lòng kiểm tra kết nối',
        errorHint:
          'Hãy kiểm tra kết nối Internet và tải lại trang. Nếu sự cố vẫn tiếp diễn, vui lòng liên hệ quản trị viên hệ thống.',
      },
    },
    en: {
      qr: {
        title: 'Preparing your order screen',
        body: 'Please wait while we load the menu.',
        status: 'Loading menu',
        errorTitle: 'Unable to open the order screen',
        errorBody: 'There was a problem loading the order screen.',
        errorStatus: 'Connection check required',
        errorHint:
          'Check your internet connection and refresh the page. If the problem continues, please ask a store team member for help.',
      },
      staff: {
        title: 'Preparing the store workspace',
        body: 'Please wait while we load the current store information.',
        status: 'Loading store workspace',
        errorTitle: 'Unable to open the store workspace',
        errorBody: 'There was a problem loading the store workspace.',
        errorStatus: 'Connection check required',
        errorHint:
          'Check your internet connection and refresh the page. If the problem continues, please contact your system administrator.',
      },
    },
  };

  const copy = shellCopy[language][isQrOrderRoute ? 'qr' : 'staff'];

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
      @font-face {
        font-family: "Pretendard";
        src: url("assets/assets/fonts/PretendardVariable.ttf") format("truetype");
        font-weight: 100 900;
        font-style: normal;
        font-display: swap;
      }

      html, body {
        background: #F5F7FA;
        color: #111827;
        margin: 0;
        width: 100%;
        height: 100%;
        min-height: 100%;
        overflow: hidden;
        font-family: "Pretendard", -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      }

      body {
        position: fixed;
        inset: 0;
        overscroll-behavior: none;
      }

      @supports (height: 100dvh) {
        html,
        body {
          height: 100dvh;
        }
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

  const failShell = () => {
    if (bootCompleted || bootFailed) {
      return;
    }
    bootFailed = true;
    renderShell({
      title: copy.errorTitle,
      bodyText: copy.errorBody,
      statusText: copy.errorStatus,
      hintText: copy.errorHint,
      hintClassName: 'globos-web-shell__hint--error',
    });
  };

  renderShell({
    title: copy.title,
    bodyText: copy.body,
    statusText: copy.status,
    hintText: '',
  });

  const bootWatchdog = window.setTimeout(() => {
    if (!bootCompleted && !hasFlutterView()) {
      failShell();
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
  }).catch(() => {
    failShell();
  });
})();
