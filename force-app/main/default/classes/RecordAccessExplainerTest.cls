@IsTest
private class RecordAccessExplainerTest {

    private static User makeUser(String alias) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            Alias = alias,
            Email = alias + '@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Tester ' + alias,
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'Asia/Kolkata',
            Username = alias + '.' + Datetime.now().getTime() + '@example.com.rae'
        );
        insert u;
        return u;
    }

    private static Boolean hasSource(RecordAccessExplainer.AccessResult result, String source) {
        for (RecordAccessExplainer.AccessReason r : result.reasons) {
            if (r.source == source) {
                return true;
            }
        }
        return false;
    }

    @IsTest
    static void ownerIsExplainedAsOwnership() {
        User owner = makeUser('rae1');
        Account acc;
        System.runAs(owner) {
            acc = new Account(Name = 'Access Explainer Test');
            insert acc;
        }

        Test.startTest();
        RecordAccessExplainer.AccessResult result = RecordAccessExplainer.explain(owner.Id, acc.Id);
        Test.stopTest();

        Assert.areEqual('Account', result.objectName, 'Object name should be resolved from the record Id');
        Assert.isTrue(result.hasRead, 'The owner must be able to read the record');
        Assert.isTrue(hasSource(result, 'Ownership'), 'Ownership should be listed as a reason');
        Assert.isNotNull(result.internalSharingModel, 'Org-wide default should be returned');
    }

    @IsTest
    static void nonOwnerGetsAnExplanation() {
        User owner = makeUser('rae2');
        User other = makeUser('rae3');
        Account acc;
        System.runAs(owner) {
            acc = new Account(Name = 'Access Explainer Test 2');
            insert acc;
        }

        Test.startTest();
        RecordAccessExplainer.AccessResult result = RecordAccessExplainer.explain(other.Id, acc.Id);
        Test.stopTest();

        Assert.isFalse(hasSource(result, 'Ownership'), 'A non-owner must not be reported as the owner');
        Assert.isTrue(hasSource(result, 'Object Permission'), 'Standard User has object access to Account');
        if (result.hasRead) {
            Assert.isFalse(result.reasons.isEmpty(), 'If the user can read the record, a reason or warning should explain why');
        }
    }

    @IsTest
    static void missingInputsAreRejected() {
        try {
            RecordAccessExplainer.explain(null, null);
            Assert.fail('An exception was expected');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('Please choose'), 'A friendly message should be returned');
        }
    }

    @IsTest
    static void invalidRecordIsReportedAsError() {
        User u = makeUser('rae4');
        Id deletedId;
        System.runAs(u) {
            Account acc = new Account(Name = 'Deleted record');
            insert acc;
            deletedId = acc.Id;
            delete acc;
        }

        try {
            RecordAccessExplainer.explain(u.Id, deletedId);
            Assert.fail('An exception was expected for a deleted record');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e.getMessage(), 'The error should be passed back to the component');
        }
    }
}
