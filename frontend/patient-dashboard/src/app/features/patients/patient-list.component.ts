// src/app/features/patients/patient-list.component.ts
//
// Patient list with pagination.
// Shows only non-PHI fields in the list; PHI is only shown in detail view
// (requires explicit user action — ALCOA+ audit trail records each access).

import { Component, OnInit, inject, signal } from '@angular/core';
import { CommonModule }   from '@angular/common';
import { RouterModule }   from '@angular/router';
import { PatientService, Patient, PaginatedResult } from '../../core/services/patient.service';

@Component({
  selector:    'app-patient-list',
  standalone:  true,
  imports:     [CommonModule, RouterModule],
  template: `
    <div class="patient-list">
      <h1>Patient Dashboard</h1>

      <div *ngIf="loading()" class="loading">Loading patients...</div>

      <div *ngIf="error()" class="error">{{ error() }}</div>

      <table *ngIf="!loading() && result()">
        <thead>
          <tr>
            <th>ID</th>
            <th>Trial</th>
            <th>Status</th>
            <th>Created</th>
          </tr>
        </thead>
        <tbody>
          <tr *ngFor="let p of result()?.items">
            <td><a [routerLink]="['/patients', p.id]">{{ p.id | slice:0:8 }}...</a></td>
            <td>{{ p.trialId | slice:0:8 }}</td>
            <td>{{ p.status }}</td>
            <td>{{ p.createdAt | date:'short' }}</td>
          </tr>
        </tbody>
      </table>

      <div class="pagination" *ngIf="result()">
        <button (click)="prevPage()" [disabled]="page() === 1">Previous</button>
        <span>Page {{ page() }} of {{ result()?.totalPages }}</span>
        <button (click)="nextPage()" [disabled]="page() >= (result()?.totalPages ?? 1)">Next</button>
      </div>
    </div>
  `,
})
export class PatientListComponent implements OnInit {
  private patientService = inject(PatientService);

  loading = signal(false);
  error   = signal<string | null>(null);
  result  = signal<PaginatedResult<Patient> | null>(null);
  page    = signal(1);

  ngOnInit() { this.load(); }

  load() {
    this.loading.set(true);
    this.error.set(null);
    this.patientService.getAll(this.page()).subscribe({
      next:  res  => { this.result.set(res); this.loading.set(false); },
      error: err  => { this.error.set(err.message); this.loading.set(false); },
    });
  }

  prevPage() { if (this.page() > 1) { this.page.update(p => p - 1); this.load(); } }
  nextPage() {
    if (this.page() < (this.result()?.totalPages ?? 1)) {
      this.page.update(p => p + 1);
      this.load();
    }
  }
}
