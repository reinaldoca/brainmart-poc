// src/app/core/interceptors/auth.interceptor.ts
//
// JWT HttpOnly Cookie interceptor.
// Adds withCredentials: true to every request so the browser
// sends the HttpOnly cookie containing the JWT to the API.
// This is more secure than storing tokens in localStorage (prevents XSS theft).

import { HttpInterceptorFn } from '@angular/common/http';

export const authInterceptor: HttpInterceptorFn = (req, next) => {
  // Clone the request to add withCredentials for JWT HttpOnly cookie
  const authReq = req.clone({ withCredentials: true });
  return next(authReq);
};
