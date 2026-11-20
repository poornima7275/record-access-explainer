/**
 * RecordAccessExplainer
 *
 * Answers the classic Salesforce support question:
 *   "Why can (or can't) this user see this record?"
 *
 * It combines the platform's own calculation (UserRecordAccess) with the
 * individual layers of the security model, so an admin can see WHERE the
 * access comes from:
 *   1. System permissions   (View All Data / Modify All Data)
 *   2. Object permissions   (profile + permission sets, incl. View All / Modify All)
 *   3. Org-wide default     (internal sharing model)
 *   4. Ownership            (user, queue, role hierarchy)
 *   5. Share records        (manual, sharing rules, Apex managed sharing, teams)
 *
 * Intended for administrators: run it as a user with View Setup and
 * View All Data so every layer can be inspected.
 */
public inherited sharing class RecordAccessExplainer {

    private static final Set<String> PUBLIC_MODELS = new Set<String>{
        'Read', 'ReadWrite', 'ReadWriteTransfer', 'FullAccess'
    };

    public class AccessReason {
        @AuraEnabled public String source;
        @AuraEnabled public String detail;
        @AuraEnabled public String accessLevel;

        public AccessReason(String source, String detail, String accessLevel) {
            this.source = source;
            this.detail = detail;
            this.accessLevel = accessLevel;
        }
    }

    public class AccessResult {
        @AuraEnabled public String objectName;
        @AuraEnabled public String objectLabel;
        @AuraEnabled public Boolean hasRead = false;
        @AuraEnabled public Boolean hasEdit = false;
        @AuraEnabled public Boolean hasDelete = false;
        @AuraEnabled public String maxAccessLevel;
        @AuraEnabled public String internalSharingModel;
        @AuraEnabled public List<AccessReason> reasons = new List<AccessReason>();
        @AuraEnabled public List<String> warnings = new List<String>();
    }

    /**
     * Entry point for the Lightning Web Component.
     */
    @AuraEnabled
    public static AccessResult explain(Id userId, Id recordId) {
        if (userId == null || recordId == null) {
            AuraHandledException ex = new AuraHandledException('Please choose a user and enter a record Id.');
            ex.setMessage('Please choose a user and enter a record Id.');
            throw ex;
        }
        try {
            return buildResult(userId, recordId);
        } catch (Exception e) {
            AuraHandledException ex = new AuraHandledException(e.getMessage());
            ex.setMessage(e.getMessage());
            throw ex;
        }
    }

    @TestVisible
    private static AccessResult buildResult(Id userId, Id recordId) {
        AccessResult result = new AccessResult();
        Schema.DescribeSObjectResult describe = recordId.getSobjectType().getDescribe();
        result.objectName = describe.getName();
        result.objectLabel = describe.getLabel();

        addEffectiveAccess(result, userId, recordId);
        Set<Id> permSetIds = getPermissionSetIds(userId);
        addSystemPermissions(result, permSetIds);
        addObjectPermissions(result, permSetIds);
        addOrgWideDefault(result);
        User u = [SELECT Id, UserRoleId, UserType FROM User WHERE Id = :userId];
        addOwnership(result, describe, u, recordId);
        addShares(result, describe, u, recordId);

        if (result.hasRead && result.reasons.isEmpty()) {
            result.warnings.add('The user has access, but it comes from a source this tool does not inspect '
                + '(for example implicit sharing from a parent or child record, territories, or external sharing).');
        }
        return result;
    }

    // 1. What the platform says the user can do with the record
    private static void addEffectiveAccess(AccessResult result, Id userId, Id recordId) {
        List<UserRecordAccess> access = [
            SELECT RecordId, HasReadAccess, HasEditAccess, HasDeleteAccess, MaxAccessLevel
            FROM UserRecordAccess
            WHERE UserId = :userId AND RecordId = :recordId
        ];
        if (!access.isEmpty()) {
            result.hasRead = access[0].HasReadAccess;
            result.hasEdit = access[0].HasEditAccess;
            result.hasDelete = access[0].HasDeleteAccess;
            result.maxAccessLevel = access[0].MaxAccessLevel;
        }
    }

    // Profile permission set + all assigned permission sets
    private static Set<Id> getPermissionSetIds(Id userId) {
        Set<Id> ids = new Set<Id>();
        for (PermissionSetAssignment psa : [
            SELECT PermissionSetId FROM PermissionSetAssignment WHERE AssigneeId = :userId
        ]) {
            ids.add(psa.PermissionSetId);
        }
        return ids;
    }

    // 2. View All Data / Modify All Data override everything
    private static void addSystemPermissions(AccessResult result, Set<Id> permSetIds) {
        for (PermissionSet ps : [
            SELECT Label, IsOwnedByProfile, Profile.Name, PermissionsViewAllData, PermissionsModifyAllData
            FROM PermissionSet
            WHERE Id IN :permSetIds
            AND (PermissionsViewAllData = true OR PermissionsModifyAllData = true)
        ]) {
            Boolean modifyAll = ps.PermissionsModifyAllData;
            result.reasons.add(new AccessReason(
                'System Permission',
                (modifyAll ? 'Modify All Data' : 'View All Data') + ' via ' + describeSource(ps.IsOwnedByProfile, ps.Profile.Name, ps.Label),
                modifyAll ? 'All' : 'Read'
            ));
        }
    }

    // 3. Object-level CRUD, View All and Modify All
    private static void addObjectPermissions(AccessResult result, Set<Id> permSetIds) {
        Boolean canRead = false;
        for (ObjectPermissions op : [
            SELECT Parent.Label, Parent.IsOwnedByProfile, Parent.Profile.Name,
                PermissionsRead, PermissionsEdit, PermissionsDelete,
                PermissionsViewAllRecords, PermissionsModifyAllRecords
            FROM ObjectPermissions
            WHERE SobjectType = :result.objectName AND ParentId IN :permSetIds
        ]) {
            canRead = canRead || op.PermissionsRead;
            String source = describeSource(op.Parent.IsOwnedByProfile, op.Parent.Profile.Name, op.Parent.Label);
            if (op.PermissionsModifyAllRecords || op.PermissionsViewAllRecords) {
                result.reasons.add(new AccessReason(
                    'Object Permission',
                    (op.PermissionsModifyAllRecords ? 'Modify All' : 'View All') + ' on ' + result.objectLabel + ' via ' + source,
                    op.PermissionsModifyAllRecords ? 'All' : 'Read'
                ));
            } else if (op.PermissionsRead) {
                List<String> crud = new List<String>{ 'Read' };
                if (op.PermissionsEdit) { crud.add('Edit'); }
                if (op.PermissionsDelete) { crud.add('Delete'); }
                result.reasons.add(new AccessReason(
                    'Object Permission',
                    String.join(crud, ', ') + ' on ' + result.objectLabel + ' via ' + source
                        + ' (object access only: record access still needs sharing)',
                    'Object level'
                ));
            }
        }
        if (!canRead) {
            result.warnings.add('The user has no Read permission on ' + result.objectLabel
                + '. Sharing cannot grant access without object permission.');
        }
    }

    // 4. Org-wide default (internal sharing model)
    private static void addOrgWideDefault(AccessResult result) {
        List<EntityDefinition> defs = [
            SELECT InternalSharingModel FROM EntityDefinition
            WHERE QualifiedApiName = :result.objectName LIMIT 1
        ];
        if (defs.isEmpty()) {
            return;
        }
        result.internalSharingModel = defs[0].InternalSharingModel;
        if (PUBLIC_MODELS.contains(result.internalSharingModel)) {
            result.reasons.add(new AccessReason(
                'Org-Wide Default',
                'Internal sharing model is Public ' + result.internalSharingModel,
                result.internalSharingModel
            ));
        } else if (result.internalSharingModel == 'ControlledByParent') {
            result.warnings.add('Access to ' + result.objectLabel + ' is controlled by its parent record. '
                + 'Check the parent record to see the full picture.');
        }
    }

    // 5. Ownership: direct owner, queue member, or role hierarchy
    private static void addOwnership(AccessResult result, Schema.DescribeSObjectResult describe, User u, Id recordId) {
        if (!describe.fields.getMap().containsKey('ownerid')) {
            return;
        }
        List<SObject> records = Database.query('SELECT OwnerId FROM ' + result.objectName + ' WHERE Id = :recordId');
        if (records.isEmpty()) {
            throw new QueryException('Record not found or not accessible: ' + recordId);
        }
        Id ownerId = (Id) records[0].get('OwnerId');

        if (ownerId == u.Id) {
            result.reasons.add(new AccessReason('Ownership', 'The user owns this record', 'All'));
            return;
        }

        if (ownerId.getSobjectType() == Group.SObjectType) {
            List<GroupMember> members = [
                SELECT Id FROM GroupMember WHERE GroupId = :ownerId AND UserOrGroupId = :u.Id
            ];
            if (!members.isEmpty()) {
                result.reasons.add(new AccessReason('Ownership', 'The record is owned by a queue the user belongs to', 'All'));
            }
            return;
        }

        User owner = [SELECT Name, UserRoleId FROM User WHERE Id = :ownerId];
        if (u.UserRoleId != null && owner.UserRoleId != null && isAboveInHierarchy(u.UserRoleId, owner.UserRoleId)) {
            result.reasons.add(new AccessReason(
                'Role Hierarchy',
                'The user\'s role is above the role of the owner (' + owner.Name + ')',
                'Same as owner'
            ));
        }
    }

    private static Boolean isAboveInHierarchy(Id managerRoleId, Id ownerRoleId) {
        Map<Id, Id> parentOf = new Map<Id, Id>();
        for (UserRole r : [SELECT Id, ParentRoleId FROM UserRole]) {
            parentOf.put(r.Id, r.ParentRoleId);
        }
        Id current = parentOf.get(ownerRoleId);
        Integer guard = 0;
        while (current != null && guard < 100) {
            if (current == managerRoleId) {
                return true;
            }
            current = parentOf.get(current);
            guard++;
        }
        return false;
    }

    // 6. Explicit share records (manual, sharing rules, Apex sharing, teams)
    private static void addShares(AccessResult result, Schema.DescribeSObjectResult describe, User u, Id recordId) {
        String shareObject;
        String parentField;
        String accessField;
        if (describe.isCustom()) {
            shareObject = result.objectName.removeEnd('__c') + '__Share';
            parentField = 'ParentId';
            accessField = 'AccessLevel';
        } else {
            shareObject = result.objectName + 'Share';
            parentField = result.objectName + 'Id';
            accessField = result.objectName + 'AccessLevel';
        }

        if (!Schema.getGlobalDescribe().containsKey(shareObject.toLowerCase())) {
            result.warnings.add('There is no share table for ' + result.objectLabel
                + ' (its org-wide default is probably Public Read/Write or Controlled by Parent).');
            return;
        }

        Set<Id> groupIds = getGroupIdsForUser(u);
        String soql = 'SELECT UserOrGroupId, RowCause, ' + accessField
            + ' FROM ' + shareObject + ' WHERE ' + parentField + ' = :recordId';

        List<SObject> matching = new List<SObject>();
        Set<Id> groupsToName = new Set<Id>();
        for (SObject share : Database.query(soql)) {
            Id target = (Id) share.get('UserOrGroupId');
            String cause = (String) share.get('RowCause');
            if (cause == 'Owner') {
                continue; // already covered by the ownership check
            }
            if (target == u.Id || groupIds.contains(target)) {
                matching.add(share);
                if (target != u.Id) {
                    groupsToName.add(target);
                }
            }
        }

        Map<Id, Group> groupNames = new Map<Id, Group>(
            [SELECT Id, Name, DeveloperName, Type FROM Group WHERE Id IN :groupsToName]
        );
        for (SObject share : matching) {
            Id target = (Id) share.get('UserOrGroupId');
            String detail = target == u.Id
                ? 'Shared directly with the user'
                : 'Shared with ' + describeGroup(groupNames.get(target)) + ', which includes the user';
            result.reasons.add(new AccessReason(
                'Sharing (' + String.valueOf(share.get('RowCause')) + ')',
                detail,
                String.valueOf(share.get(accessField))
            ));
        }
    }

    // Groups the user belongs to: public groups, queues, role groups (and nested groups)
    private static Set<Id> getGroupIdsForUser(User u) {
        Set<Id> result = new Set<Id>();

        for (GroupMember gm : [SELECT GroupId FROM GroupMember WHERE UserOrGroupId = :u.Id]) {
            result.add(gm.GroupId);
        }

        if (u.UserRoleId != null) {
            Set<Id> roleAndAncestors = new Set<Id>{ u.UserRoleId };
            Map<Id, Id> parentOf = new Map<Id, Id>();
            for (UserRole r : [SELECT Id, ParentRoleId FROM UserRole]) {
                parentOf.put(r.Id, r.ParentRoleId);
            }
            Id current = parentOf.get(u.UserRoleId);
            Integer guard = 0;
            while (current != null && guard < 100) {
                roleAndAncestors.add(current);
                current = parentOf.get(current);
                guard++;
            }
            for (Group g : [
                SELECT Id, Type, RelatedId FROM Group
                WHERE RelatedId IN :roleAndAncestors
                AND Type IN ('Role', 'RoleAndSubordinates', 'RoleAndSubordinatesInternal')
            ]) {
                // A plain "Role" group only includes users in exactly that role
                if (g.Type == 'Role' && g.RelatedId != u.UserRoleId) {
                    continue;
                }
                result.add(g.Id);
            }
        }

        if (u.UserType == 'Standard') {
            for (Group g : [SELECT Id FROM Group WHERE Type = 'Organization']) {
                result.add(g.Id);
            }
        }

        // Expand nested public groups a few levels deep
        Set<Id> frontier = result.clone();
        for (Integer depth = 0; depth < 3 && !frontier.isEmpty(); depth++) {
            Set<Id> next = new Set<Id>();
            for (GroupMember gm : [SELECT GroupId FROM GroupMember WHERE UserOrGroupId IN :frontier]) {
                if (!result.contains(gm.GroupId)) {
                    next.add(gm.GroupId);
                }
            }
            result.addAll(next);
            frontier = next;
        }
        return result;
    }

    private static String describeSource(Boolean isProfile, String profileName, String permSetLabel) {
        return isProfile ? 'profile "' + profileName + '"' : 'permission set "' + permSetLabel + '"';
    }

    private static String describeGroup(Group g) {
        if (g == null) {
            return 'a group';
        }
        String name = String.isNotBlank(g.Name) ? g.Name : g.DeveloperName;
        if (g.Type == 'Organization') {
            return 'All Internal Users';
        }
        if (g.Type == 'Role' || g.Type == 'RoleAndSubordinates' || g.Type == 'RoleAndSubordinatesInternal') {
            return 'role group (' + g.Type + ')';
        }
        return (g.Type == 'Queue' ? 'queue "' : 'public group "') + name + '"';
    }
}
