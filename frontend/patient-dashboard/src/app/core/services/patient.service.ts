// src/app/core/services/patient.service.ts
//
// Patient API service — wraps the Patient Service REST API.
// All PHI is encrypted server-side with KMS; this service
// handles only the HTTP transport layer.

import { Injectable }   from '@angular/core';
import { HttpClient, HttpParams } from '@angular/common/http';
import { environment }  from '../../../environments/environment';

export interface Patient {
  id:          string;
  firstName:   string;
  lastName:    string;
  documentId:  string;
  email:       string;
  address?:    string;
  trialId:     string;
  consentDate: string;
  status:      'Active' | 'Withdrawn' | 'Completed' | 'Anonymized';
  createdAt:   string;
  createdBy:   string;
}

export interface PaginatedResult<T> {
  items:      T[];
  totalCount: number;
  page:       number;
  pageSize:   number;
  totalPages: number;
}

export interface CreatePatientRequest {
  firstName:   string;
  lastName:    string;
  documentId:  string;
  email:       string;
  address?:    string;
  trialId:     string;
  consentDate: string;
}

@Injectable({ providedIn: 'root' })
export class PatientService {
  private readonly url = `${environment.apiUrl}/api/v1/patients`;

  constructor(private http: HttpClient) {}

  getAll(page = 1, pageSize = 20, trialId?: string) {
    let params = new HttpParams()
      .set('page',     page.toString())
      .set('pageSize', pageSize.toString());
    if (trialId) params = params.set('trialId', trialId);
    return this.http.get<PaginatedResult<Patient>>(this.url, { params, withCredentials: true });
  }

  getById(id: string) {
    return this.http.get<Patient>(`${this.url}/${id}`, { withCredentials: true });
  }

  create(request: CreatePatientRequest) {
    return this.http.post<Patient>(this.url, request, { withCredentials: true });
  }

  anonymize(id: string) {
    return this.http.post<void>(`${this.url}/${id}/anonymize`, {}, { withCredentials: true });
  }

  getAuditTrail(id: string, from?: string, to?: string) {
    let params = new HttpParams();
    if (from) params = params.set('from', from);
    if (to)   params = params.set('to',   to);
    return this.http.get<unknown[]>(`${this.url}/${id}/audit-trail`, { params, withCredentials: true });
  }
}
