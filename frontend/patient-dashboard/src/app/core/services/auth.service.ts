// src/app/core/services/auth.service.ts
//
// Authentication service.
// Communicates with the Patient Service API for login/logout.
// JWT is stored as an HttpOnly cookie by the server — this service
// never handles the token directly (XSS protection).

import { Injectable, signal } from '@angular/core';
import { HttpClient }         from '@angular/common/http';
import { tap }                from 'rxjs/operators';
import { environment }        from '../../../environments/environment';

export interface LoginRequest  { email: string; password: string; }
export interface LoginResponse { expiresAt: string; userId: string; }

@Injectable({ providedIn: 'root' })
export class AuthService {
  private readonly _authenticated = signal(false);

  readonly isAuthenticated = this._authenticated.asReadonly();

  constructor(private http: HttpClient) {}

  login(credentials: LoginRequest) {
    return this.http
      .post<LoginResponse>(`${environment.apiUrl}/auth/login`, credentials, {
        withCredentials: true,  // receive HttpOnly JWT cookie
      })
      .pipe(tap(() => this._authenticated.set(true)));
  }

  logout() {
    return this.http
      .post<void>(`${environment.apiUrl}/auth/logout`, {}, { withCredentials: true })
      .pipe(tap(() => this._authenticated.set(false)));
  }
}
