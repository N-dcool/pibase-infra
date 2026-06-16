// —— PiBase CloudFlare Worker ————
// Route: db.nareshchoudhary.com/*
//
// Routes /api/* to the Pi backend (via Cloudflare Tunnel)
// Routes everything else to Vercel (Next.js frontend)
// Returns 503 maintenance JSON if Pi is unreachable
//
// No CORS issues -- broweser sees same origin (db.nareshchoudhary.com) for both frontend and backend
//
// manually deployed via cloudfare workers dashboard (no CI/CD yet)

const PI_BACKEND = "https://backend.nareshchoudhary.com";
const VERCEL_FRONTEND = "https://db-service-ui.vercel.app";

function isPiRoute(path) {
  return path.startsWith("/api/");
}

function maintenanceResponse() {
  return new Response(
    JSON.stringify({
      error: "maintenance",
      message: "Backend is temporarily unavailable. Please try again later.",
    }),
    {
      status: 503,
      headers: { "Content-Type": "application/json" },
    },
  );
}

async function handleRequest(request) {
  const url = new URL(request.url);
  const path = url.pathname;
  const body =
    request.method !== "GET" && request.method !== "HEAD"
      ? request.body
      : undefined;

  // — API routes → Pi backend —
  if (isPiRoute(path)) {
    const backendUrl = PI_BACKEND + path + url.search;

    try {
      const res = await fetch(backendUrl, {
        method: request.method,
        headers: request.headers,
        body,
        redirect: "follow",
      });

      if (res.status === 404 || res.status >= 500) {
        const contentType = res.headers.get("Content-Type") || "";

        // Pi is responding with JSON error (e.g. 404 for missing resource) → forward as is
        if (contentType.includes("application/json")) {
          return res;
        }

        return maintenanceResponse();
      }

      return res;
    } catch (error) {
      console.error("Error fetching from Pi backend:", error);
      // Network-level failure (e.g. Pi is down, tunnel issue) → return maintenance response
      // Pi is down → maintenance mode
      return maintenanceResponse();
    }
  }

  // — Everything else → Vercel frontend —
  const vercelUrl = VERCEL_FRONTEND + path + url.search;

  return await fetch(vercelUrl, {
    method: request.method,
    headers: request.headers,
    body,
  });
}

export default {
  fetch: handleRequest,
};
