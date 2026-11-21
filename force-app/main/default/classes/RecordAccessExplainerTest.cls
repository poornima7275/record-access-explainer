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
    static void adminAccessComesFromSystemPermissions() {
        User owner = makeUser('rae5');
        Account acc;
        System.runAs(owner) {
            acc = new Account(Name = 'Admin access test');
            insert acc;
        }

        Test.startTest();
        // The test runs as a System Administrator, who has View All / Modify All Data
        RecordAccessExplainer.AccessResult result = RecordAccessExplainer.explain(UserInfo.getUserId(), acc.Id);
        Test.stopTest();

        Assert.isTrue(result.hasRead, 'An administrator can read every record');
        Assert.isTrue(
            hasSource(result, 'System Permission') || hasSource(result, 'Object Permission'),
            'Admin access should be explained by a system or object permission'
        );
    }

    @IsTest
    static void managerAccessComesFromRoleHierarchy() {
        UserRole managerRole = new UserRole(Name = 'RAE Manager', DeveloperName = 'RAE_Manager_Test');
        insert managerRole;
        UserRole repRole = new UserRole(Name = 'RAE Rep', DeveloperName = 'RAE_Rep_Test', ParentRoleId = managerRole.Id);
        insert repRole;

        User manager = makeUser('rae6');
        User rep = makeUser('rae7');
        manager.UserRoleId = managerRole.Id;
        rep.UserRoleId = repRole.Id;
        update new List<User>{ manager, rep };

        Account acc;
        System.runAs(rep) {
            acc = new Account(Name = 'Role hierarchy test');
            insert acc;
        }

        Test.startTest();
        RecordAccessExplainer.AccessResult result = RecordAccessExplainer.explain(manager.Id, acc.Id);
        Test.stopTest();

        Assert.isTrue(hasSource(result, 'Role Hierarchy'), 'The manager should get access through the role hierarchy');
    }

    @IsTest
    static void queueMemberIsExplainedAsOwnership() {
        User member = makeUser('rae8');
        Group queue = new Group(Name = 'RAE Test Queue', DeveloperName = 'RAE_Test_Queue', Type = 'Queue');
        insert queue;
        insert new QueueSobject(QueueId = queue.Id, SobjectType = 'Lead');
        insert new GroupMember(GroupId = queue.Id, UserOrGroupId = member.Id);

        Lead lead;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            lead = new Lead(LastName = 'Queue Lead', Company = 'RAE', OwnerId = queue.Id);
            insert lead;
        }

        Test.startTest();
        RecordAccessExplainer.AccessResult result = RecordAccessExplainer.explain(member.Id, lead.Id);
        Test.stopTest();

        Assert.isTrue(hasSource(result, 'Ownership'), 'A queue member should be explained as owner through the queue');
    }

    @IsTest
    static void manualShareIsDetectedWhenSharingIsPrivate() {
        User owner = makeUser('rae9');
        User viewer = makeUser('rae0');
        Account acc;
        System.runAs(owner) {
            acc = new Account(Name = 'Manual share test');
            insert acc;
        }

        Boolean shareCreated = false;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            try {
                insert new AccountShare(
                    AccountId = acc.Id,
                    UserOrGroupId = viewer.Id,
                    AccountAccessLevel = 'Read',
                    OpportunityAccessLevel = 'None'
                );
                shareCreated = true;
            } catch (DmlException e) {
                // Manual shares are not allowed when the Account org-wide default is Public Read/Write
                shareCreated = false;
            }
        }

        Test.startTest();
        RecordAccessExplainer.AccessResult result = RecordAccessExplainer.explain(viewer.Id, acc.Id);
        Test.stopTest();

        if (shareCreated) {
            Assert.isTrue(hasSource(result, 'Sharing (Manual)'), 'The manual share should be listed');
        } else {
            Assert.isTrue(hasSource(result, 'Org-Wide Default'), 'With public sharing the org-wide default explains access');
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
