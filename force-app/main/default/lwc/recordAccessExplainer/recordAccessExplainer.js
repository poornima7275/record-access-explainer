import { LightningElement } from 'lwc';
import explain from '@salesforce/apex/RecordAccessExplainer.explain';

const COLUMNS = [
    { label: 'Source', fieldName: 'source', initialWidth: 190 },
    { label: 'Detail', fieldName: 'detail', wrapText: true },
    { label: 'Access', fieldName: 'accessLevel', initialWidth: 130 }
];

export default class RecordAccessExplainer extends LightningElement {
    columns = COLUMNS;
    userId;
    recordIdInput = '';
    result;
    error;
    isLoading = false;

    get isDisabled() {
        return !this.userId || !this.recordIdInput || this.isLoading;
    }

    get hasReasons() {
        return this.reasonRows.length > 0;
    }

    get reasonRows() {
        return (this.result?.reasons || []).map((reason, index) => ({ ...reason, key: index }));
    }

    get warningRows() {
        return (this.result?.warnings || []).map((text, index) => ({ text, key: index }));
    }

    get owdLabel() {
        return this.result?.internalSharingModel || 'Unknown';
    }

    get maxAccess() {
        return this.result?.maxAccessLevel || 'None';
    }

    get readText() {
        return this.result?.hasRead ? 'Yes' : 'No';
    }

    get editText() {
        return this.result?.hasEdit ? 'Yes' : 'No';
    }

    get deleteText() {
        return this.result?.hasDelete ? 'Yes' : 'No';
    }

    get readClass() {
        return this.pillClass(this.result?.hasRead);
    }

    get editClass() {
        return this.pillClass(this.result?.hasEdit);
    }

    get deleteClass() {
        return this.pillClass(this.result?.hasDelete);
    }

    pillClass(granted) {
        return granted ? 'pill pill-yes' : 'pill pill-no';
    }

    handleUserChange(event) {
        this.userId = event.detail.recordId;
    }

    handleRecordChange(event) {
        this.recordIdInput = (event.target.value || '').trim();
    }

    async handleExplain() {
        this.isLoading = true;
        this.error = undefined;
        this.result = undefined;
        try {
            this.result = await explain({ userId: this.userId, recordId: this.recordIdInput });
        } catch (e) {
            this.error = e?.body?.message || 'Something went wrong while checking access.';
        } finally {
            this.isLoading = false;
        }
    }
}
